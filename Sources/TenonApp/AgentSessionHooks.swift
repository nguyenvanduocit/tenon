// @domain: agent-lens
import Darwin
import Foundation

/// The work a lifecycle hook reports beyond session identity. Each field is a bounded
/// value copied out of the provider's payload at the request boundary, so nothing the
/// provider sent stays alive inside the host as an untyped document.
struct AgentHookActivity: Equatable, Sendable {
    var toolName: String?
    var toolUseID: String?
    var toolInputJSON: String?
    var toolResponseJSON: String?
    var isToolError = false
    var message: String?
    var permissionMode: String?
    var lastAssistantMessage: String?
    var reason: String?
    var workingDirectory: String?

    static let none = Self()

    var isEmpty: Bool { self == .none }
}

/// One provider lifecycle fact delivered by a hook running inside a terminal surface.
/// The hook is an EVENT adapter; the registry below is host-private DIRECT state.
struct AgentHookEvent: Equatable, Sendable {
    let paneID: UUID
    let surfaceToken: UUID
    let provider: AgentProvider
    let sessionID: String
    let transcriptPath: String?
    let hookEventName: String
    let agentID: String?
    let processGroupID: UInt64?
    let activity: AgentHookActivity

    init(
        paneID: UUID,
        surfaceToken: UUID,
        provider: AgentProvider,
        sessionID: String,
        transcriptPath: String?,
        hookEventName: String,
        agentID: String?,
        processGroupID: UInt64? = nil,
        activity: AgentHookActivity = .none
    ) {
        self.paneID = paneID
        self.surfaceToken = surfaceToken
        self.provider = provider
        self.sessionID = sessionID
        self.transcriptPath = transcriptPath
        self.hookEventName = hookEventName
        self.agentID = agentID
        self.processGroupID = processGroupID
        self.activity = activity
    }
}

struct AgentSessionBinding: Equatable, Sendable {
    let provider: AgentProvider
    let sessionID: String
    let transcriptURL: URL
    let hookEventName: String
    let processGroupID: UInt64?
}

/// Binds a provider's root session to the exact incarnation of a terminal surface.
/// Reusing a slot UUID cannot revive a binding because each materialized PTY receives a
/// new, host-minted surface token. Subagent facts never replace the root resource.
actor AgentSessionRegistry {
    private struct Key: Hashable {
        let paneID: UUID
        let surfaceToken: UUID
    }

    private static let capacity = 256
    private let allowedTranscriptRoots: [URL]
    private var bindings: [Key: AgentSessionBinding] = [:]
    /// Session IDs a later start has already replaced on this surface. A provider keeps firing
    /// hooks from a session the terminal has moved on from, and they arrive after the ones that
    /// replaced it. Ordering by the terminal's own event order is the only account that stays
    /// true while the transcript is not yet on disk to be dated.
    private var supersededSessionIDs: [Key: Set<String>] = [:]
    private var recency: [Key] = []

    init(
        allowedTranscriptRoots: [URL] = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/sessions", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects", isDirectory: true),
        ]
    ) {
        self.allowedTranscriptRoots = allowedTranscriptRoots.map {
            $0.resolvingSymlinksInPath().standardizedFileURL
        }
    }

    /// Binds the path the hook declares, whether or not anything exists at it yet.
    ///
    /// Claude Code buffers a session and writes its JSONL at the first prompt, back-stamping the
    /// records it was already holding — measured here as 27 seconds between a session's first
    /// record and the file's own birth. The hook names the right path for that whole window, so
    /// waiting on the filesystem only means the pane cannot say which session it is watching
    /// while its operator is still typing. What later appears at the path is checked where the
    /// bytes are actually read, which also covers a path swapped after this point.
    func record(_ event: AgentHookEvent) {
        guard event.agentID == nil else { return }
        guard !event.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let transcriptURL = candidateURL(for: event) else { return }
        let key = Key(paneID: event.paneID, surfaceToken: event.surfaceToken)
        bind(event, transcriptURL: transcriptURL, for: key)
        recency.removeAll { $0 == key }
        recency.append(key)
        while recency.count > Self.capacity {
            let evicted = recency.removeFirst()
            bindings.removeValue(forKey: evicted)
            supersededSessionIDs.removeValue(forKey: evicted)
        }
    }

    func binding(paneID: UUID, surfaceToken: UUID) -> AgentSessionBinding? {
        bindings[Key(paneID: paneID, surfaceToken: surfaceToken)]
    }

    func retainOnly(_ paneIDs: Set<UUID>) {
        let removed = Set(bindings.keys.filter { !paneIDs.contains($0.paneID) })
            .union(supersededSessionIDs.keys.filter { !paneIDs.contains($0.paneID) })
        for key in removed {
            bindings.removeValue(forKey: key)
            supersededSessionIDs.removeValue(forKey: key)
        }
        recency.removeAll { removed.contains($0) }
    }

    private func bind(_ event: AgentHookEvent, transcriptURL: URL, for key: Key) {
        if let existing = bindings[key], existing.sessionID != event.sessionID {
            // Only a session start moves a surface to another session, and only forwards: a
            // session this surface has already left cannot take it back when its trailing
            // hooks land.
            guard event.hookEventName == "SessionStart",
                  supersededSessionIDs[key]?.contains(event.sessionID) != true
            else { return }
            supersededSessionIDs[key, default: []].insert(existing.sessionID)
        }
        bindings[key] = AgentSessionBinding(
            provider: event.provider,
            sessionID: event.sessionID,
            transcriptURL: transcriptURL,
            hookEventName: event.hookEventName,
            processGroupID: event.processGroupID
        )
    }

    private func candidateURL(for event: AgentHookEvent) -> URL? {
        guard let transcriptPath = event.transcriptPath, transcriptPath.hasPrefix("/") else {
            return nil
        }
        let transcriptURL = URL(fileURLWithPath: transcriptPath)
            .resolvingSymlinksInPath().standardizedFileURL
        guard transcriptURL.pathExtension == "jsonl",
              allowedTranscriptRoots.contains(where: {
                  transcriptURL.path.hasPrefix($0.path + "/")
              })
        else { return nil }
        return transcriptURL
    }
}

enum AgentHookRequestError: Error, Equatable, Sendable {
    case unauthorized
    case payloadTooLarge
    case malformed
}

/// Pure HTTP-body adapter kept separate from the socket so authentication and bounds are
/// deterministic in tests. Header names are normalized internally.
enum AgentHookRequestDecoder {
    /// A tool's arguments and its result both cross this boundary — a written file's
    /// contents, a command's output. The cap is the same order as one transcript record so
    /// an ordinary call is never silently dropped, and the fields below are capped again
    /// before anything is retained.
    static let maxBodyBytes = 2 << 20
    private static let maxFieldBytes = 32 << 10
    static let acceptedEvents = Set([
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "Notification",
        "Stop",
    ])

    private struct Payload: Decodable {
        let sessionID: String
        let transcriptPath: String?
        let hookEventName: String
        let agentID: String?
        let cwd: String?
        let toolName: String?
        let toolUseID: String?
        let message: String?
        let permissionMode: String?
        let lastAssistantMessage: String?
        let reason: String?

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case transcriptPath = "transcript_path"
            case hookEventName = "hook_event_name"
            case agentID = "agent_id"
            case cwd
            case toolName = "tool_name"
            case toolUseID = "tool_use_id"
            case message
            case permissionMode = "permission_mode"
            case lastAssistantMessage = "last_assistant_message"
            case reason
        }
    }

    static func decode(
        headers: [String: String],
        body: Data,
        expectedBearerToken: String
    ) throws -> AgentHookEvent {
        guard body.count <= maxBodyBytes else { throw AgentHookRequestError.payloadTooLarge }
        var normalized: [String: String] = [:]
        for (name, value) in headers { normalized[name.lowercased()] = value }
        let supplied = normalized["authorization"] ?? ""
        guard constantTimeEqual(supplied, "Bearer \(expectedBearerToken)") else {
            throw AgentHookRequestError.unauthorized
        }
        guard let pane = normalized["x-tenon-pane-id"].flatMap(UUID.init(uuidString:)),
              let surface = normalized["x-tenon-surface-token"].flatMap(UUID.init(uuidString:)),
              let processGroupID = normalized["x-tenon-process-group"].flatMap(UInt64.init),
              processGroupID > 0,
              let provider = normalized["x-tenon-agent-provider"]
                .flatMap(AgentProvider.init(rawValue:)),
              let payload = try? JSONDecoder().decode(Payload.self, from: body),
              !payload.sessionID.isEmpty,
              acceptedEvents.contains(payload.hookEventName)
        else { throw AgentHookRequestError.malformed }
        return AgentHookEvent(
            paneID: pane,
            surfaceToken: surface,
            provider: provider,
            sessionID: payload.sessionID,
            transcriptPath: payload.transcriptPath,
            hookEventName: payload.hookEventName,
            agentID: payload.agentID,
            processGroupID: processGroupID,
            activity: activity(payload: payload, body: body)
        )
    }

    /// The two documents a tool call is made of stay JSON text: their shape belongs to the
    /// provider's tool, and re-encoding it into host types here would mean this boundary
    /// learning every tool Claude Code ever ships.
    private static func activity(payload: Payload, body: Data) -> AgentHookActivity {
        let document = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let response = document["tool_response"]
        return AgentHookActivity(
            toolName: payload.toolName,
            toolUseID: payload.toolUseID,
            toolInputJSON: json(document["tool_input"]),
            toolResponseJSON: json(response),
            isToolError: isError(response),
            message: capped(payload.message),
            permissionMode: capped(payload.permissionMode),
            lastAssistantMessage: capped(payload.lastAssistantMessage),
            reason: capped(payload.reason),
            workingDirectory: payload.cwd
        )
    }

    /// A document larger than the field cap is dropped rather than truncated: half a JSON
    /// document parses as nothing, and a lens that shows a mangled result is worse than one
    /// that shows the call finishing with its detail left in the terminal.
    private static func json(_ value: Any?) -> String? {
        guard let value else { return nil }
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .sortedKeys]
        ), data.count <= maxFieldBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Claude Code reports a failed call as a string that opens with its exit status.
    private static func isError(_ response: Any?) -> Bool {
        guard let text = response as? String else { return false }
        return text.hasPrefix("Error:") || text.contains("Exit code ")
    }

    private static func capped(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.utf8.count > maxFieldBytes else { return value }
        return String(value.prefix(maxFieldBytes)) + "…"
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = left.count ^ right.count
        let count = max(left.count, right.count)
        for index in 0..<count {
            let leftByte = index < left.count ? left[index] : 0
            let rightByte = index < right.count ? right[index] : 0
            difference |= Int(leftByte ^ rightByte)
        }
        return difference == 0
    }
}

/// Whether a hook event describes the session a pane has actually resolved.
///
/// A hook says what it is: which provider wrote it and which process group it came from. Both
/// are written by the client, and the pane/surface token that got it this far proves only that
/// it came from *this* PTY — not that it came from the agent running in it. The transcript
/// discovery path already refuses a binding whose declared provider or process group disagrees
/// with the live foreground process; live ingestion is the same question asked of a faster
/// channel, and it deserves the same answer.
///
/// Before the pane has resolved anything there is nothing to disagree with, and dropping those
/// events would silently lose the first seconds of every session — the surface token remains
/// the binding there, as it always was.
enum AgentHookAdmission {
    static func admits(
        _ event: AgentHookEvent,
        resolution: AgentLensResolution?,
        processGroupID: (UInt64) -> UInt64 = { pid in
            let group = getpgid(Int32(pid))
            return group > 0 ? UInt64(group) : pid
        }
    ) -> Bool {
        guard let resolution else { return true }
        guard resolution.provider == event.provider else { return false }
        guard let declared = event.processGroupID else { return true }
        return declared == processGroupID(resolution.foregroundPID)
    }
}

/// Loopback-only ingress for provider hook events. The terminal inherits the random bearer
/// token and surface token; accepted descriptors and the listener are close-on-exec so a PTY
/// cannot accidentally retain the server lifecycle.
final class AgentHookServer: @unchecked Sendable {
    let bearerToken: String
    private let lifecycleLock = NSLock()
    private var listenerPort: UInt16?
    var port: UInt16? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return listenerPort
    }

    private let onEvent: @Sendable (AgentHookEvent) -> Void
    private let connectionQueue = DispatchQueue(
        label: "tenon.agent-hook.connections",
        attributes: .concurrent
    )
    private let connectionSlots = DispatchSemaphore(value: 8)
    private var listenFD: Int32 = -1

    init(
        enabled: Bool = true,
        onEvent: @escaping @Sendable (AgentHookEvent) -> Void
    ) {
        bearerToken = UUID().uuidString
        self.onEvent = onEvent
        guard enabled, let bound = Self.bindLoopback() else { return }
        listenFD = bound.fd
        listenerPort = bound.port
        startAcceptThread()
    }

    deinit {
        stop()
    }

    func stop() {
        lifecycleLock.lock()
        let descriptor = listenFD
        listenFD = -1
        listenerPort = nil
        lifecycleLock.unlock()
        if descriptor >= 0 {
            shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
        }
    }

    private static func bindLoopback() -> (fd: Int32, port: UInt16)? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        setCloseOnExec(fd)
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: CFSwapInt32HostToBig(INADDR_LOOPBACK))
        let didBind = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard didBind == 0, listen(fd, 8) == 0 else {
            close(fd)
            return nil
        }
        var resolved = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let didResolve = withUnsafeMutablePointer(to: &resolved) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard didResolve == 0 else {
            close(fd)
            return nil
        }
        return (fd, CFSwapInt16BigToHost(resolved.sin_port))
    }

    private func startAcceptThread() {
        let descriptor = listenFD
        let thread = Thread { [weak self] in
            while true {
                let client = accept(descriptor, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    return
                }
                Self.setCloseOnExec(client)
                var noSigPipe: Int32 = 1
                setsockopt(
                    client,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    &noSigPipe,
                    socklen_t(MemoryLayout<Int32>.size)
                )
                var timeout = timeval(tv_sec: 2, tv_usec: 0)
                setsockopt(
                    client,
                    SOL_SOCKET,
                    SO_RCVTIMEO,
                    &timeout,
                    socklen_t(MemoryLayout<timeval>.size)
                )
                guard let self else {
                    close(client)
                    return
                }
                guard connectionSlots.wait(timeout: .now()) == .success else {
                    close(client)
                    continue
                }
                connectionQueue.async { [weak self, connectionSlots] in
                    defer {
                        close(client)
                        connectionSlots.signal()
                    }
                    self?.handle(client)
                }
            }
        }
        thread.name = "tenon.agent-hook"
        thread.stackSize = 1 << 20
        thread.start()
    }

    private func handle(_ client: Int32) {
        guard let request = Self.readRequest(client) else {
            Self.respond(client, status: 400, reason: "Bad Request")
            return
        }
        do {
            let event = try AgentHookRequestDecoder.decode(
                headers: request.headers,
                body: request.body,
                expectedBearerToken: bearerToken
            )
            onEvent(event)
            Self.respond(client, status: 204, reason: "No Content")
        } catch AgentHookRequestError.unauthorized {
            Self.respond(client, status: 401, reason: "Unauthorized")
        } catch AgentHookRequestError.payloadTooLarge {
            Self.respond(client, status: 413, reason: "Payload Too Large")
        } catch {
            Self.respond(client, status: 400, reason: "Bad Request")
        }
    }

    private static func readRequest(_ fd: Int32) -> (headers: [String: String], body: Data)? {
        let headerLimit = 16 << 10
        var data = Data()
        var headerEnd: Range<Data.Index>?
        let separator = Data("\r\n\r\n".utf8)
        while data.count <= headerLimit, headerEnd == nil {
            var buffer = [UInt8](repeating: 0, count: 4 << 10)
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { return nil }
            data.append(buffer, count: count)
            headerEnd = data.range(of: separator)
        }
        guard let headerEnd,
              let text = String(data: data[..<headerEnd.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard lines.first == "POST /v1/agent-events HTTP/1.1" else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        guard let contentLengthText = headers["content-length"],
              let contentLength = Int(contentLengthText),
              contentLength >= 0,
              contentLength <= AgentHookRequestDecoder.maxBodyBytes
        else { return nil }
        let bodyStart = headerEnd.upperBound
        while data.count - bodyStart < contentLength {
            var buffer = [UInt8](repeating: 0, count: min(16 << 10, contentLength))
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { return nil }
            data.append(buffer, count: count)
        }
        return (headers, Data(data[bodyStart..<(bodyStart + contentLength)]))
    }

    private static func respond(_ fd: Int32, status: Int, reason: String) {
        let bytes = Array("HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = send(fd, base, raw.count, 0)
        }
    }

    private static func setCloseOnExec(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFD)
        _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
    }
}

enum AgentHookInstallResult: Equatable, Sendable {
    case installed
    case alreadyInstalled
    case unavailable(String)
}

/// Installs one additive user-level provider hook. Existing hook groups and unknown JSON
/// fields are preserved. The provider remains the trust owner and applies its own hook
/// review and execution policy before this host-private lifecycle fact is delivered.
enum AgentHookInstaller {
    private static let marker = "tenon-agent-hook-v3"
    private static let legacyMarkers = ["tenon-agent-hook-v1", "tenon-agent-hook-v2"]

    /// Claude Code's transcript is written at turn boundaries, so the tool and question
    /// hooks are the only source that reports work while it is happening. Codex publishes
    /// the same facts over its native protocol and needs its hooks only for session
    /// identity, so it keeps the smaller set rather than paying for events twice.
    private static func events(for provider: AgentProvider) -> [String] {
        switch provider {
        case .claude:
            ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop"]
        case .codex:
            ["SessionStart", "UserPromptSubmit", "Stop"]
        }
    }

    static func install(
        provider: AgentProvider,
        scriptURL: URL,
        hooksURL: URL,
        fileManager: FileManager = .default
    ) -> AgentHookInstallResult {
        let providerName = provider.displayName
        do {
            try fileManager.createDirectory(
                at: scriptURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(script.utf8).write(to: scriptURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: scriptURL.path
            )
            try fileManager.createDirectory(
                at: hooksURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let lockFD = open(hooksURL.path + ".tenon.lock", O_CREAT | O_RDWR, 0o600)
            guard lockFD >= 0 else {
                return .unavailable("\(providerName) hook configuration lock could not be opened")
            }
            defer {
                _ = flock(lockFD, LOCK_UN)
                close(lockFD)
            }
            guard flock(lockFD, LOCK_EX) == 0 else {
                return .unavailable("\(providerName) hook configuration lock could not be acquired")
            }

            var document: [String: Any] = [:]
            var originalHooksData: Data?
            if fileManager.fileExists(atPath: hooksURL.path) {
                let existing = try Data(contentsOf: hooksURL)
                originalHooksData = existing
                guard let decoded = try JSONSerialization.jsonObject(with: existing) as? [String: Any]
                else { return .unavailable("\(providerName) hook configuration is not a JSON object") }
                document = decoded
            }
            let hooksValue = document["hooks"]
            guard hooksValue == nil || hooksValue is [String: Any] else {
                return .unavailable("\(providerName) hook configuration has a non-object hooks field")
            }
            var hooks = hooksValue as? [String: Any] ?? [:]
            let command = hookCommand(provider: provider)
            var changed = false
            for event in events(for: provider) {
                let groupsValue = hooks[event]
                guard groupsValue == nil || groupsValue is [[String: Any]] else {
                    return .unavailable("\(providerName) hook configuration has an invalid \(event) group")
                }
                var groups = groupsValue as? [[String: Any]] ?? []
                var cleanedGroups: [[String: Any]] = []
                for var group in groups {
                    guard let handlers = group["hooks"] as? [[String: Any]] else {
                        cleanedGroups.append(group)
                        continue
                    }
                    let retainedHandlers = handlers.filter { handler in
                        guard let command = handler["command"] as? String else { return true }
                        return !legacyMarkers.contains(where: command.contains)
                    }
                    if retainedHandlers.count != handlers.count {
                        changed = true
                    }
                    guard !retainedHandlers.isEmpty else { continue }
                    group["hooks"] = retainedHandlers
                    cleanedGroups.append(group)
                }
                groups = cleanedGroups
                let exists = groups.contains { group in
                    (group["hooks"] as? [[String: Any]])?.contains { handler in
                        (handler["command"] as? String)?.contains(marker) == true
                    } == true
                }
                if !exists {
                    groups.append([
                        "hooks": [[
                            "type": "command",
                            "command": command,
                            "timeout": 3,
                        ]],
                    ])
                    changed = true
                }
                hooks[event] = groups
            }
            guard changed else { return .alreadyInstalled }
            document["hooks"] = hooks
            let encoded = try JSONSerialization.data(
                withJSONObject: document,
                options: [.prettyPrinted, .sortedKeys]
            )
            if let originalHooksData {
                guard try Data(contentsOf: hooksURL) == originalHooksData else {
                    return .unavailable("Codex hooks.json changed during installation; retry")
                }
            } else if fileManager.fileExists(atPath: hooksURL.path) {
                return .unavailable("Codex hooks.json appeared during installation; retry")
            }
            try encoded.write(to: hooksURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: hooksURL.path
            )
            return .installed
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    private static func hookCommand(provider: AgentProvider) -> String {
        return "if [ -n \"${TENON_AGENT_HOOK_SCRIPT:-}\" ] && [ -r \"$TENON_AGENT_HOOK_SCRIPT\" ]; then TENON_AGENT_PROVIDER='\(provider.rawValue)' /bin/sh \"$TENON_AGENT_HOOK_SCRIPT\"; else { command -p cat 2>/dev/null || cat; } >/dev/null 2>&1 || :; fi # \(marker)"
    }

    private static let script = """
        #!/bin/sh
        if [ -z "${TENON_AGENT_HOOK_PORT:-}" ] || \
           [ -z "${TENON_AGENT_HOOK_TOKEN:-}" ] || \
           [ -z "${TENON_PANE_ID:-}" ] || \
           [ -z "${TENON_AGENT_SURFACE_TOKEN:-}" ] || \
           [ -z "${TENON_AGENT_PROVIDER:-}" ]; then
          { command -p cat 2>/dev/null || cat; } >/dev/null 2>&1 || :
          exit 0
        fi
        agent_pid=$PPID
        agent_pgid=
        while [ "${agent_pid:-0}" -gt 1 ] 2>/dev/null; do
          agent_comm=$(/bin/ps -o comm= -p "$agent_pid" 2>/dev/null)
          agent_name=${agent_comm##*/}
          agent_command=$(/bin/ps -o command= -p "$agent_pid" 2>/dev/null)
          agent_match=false
          case "$TENON_AGENT_PROVIDER" in
            claude)
              case "$agent_name:$agent_command" in
                claude:*|*:*@anthropic-ai/claude*) agent_match=true ;;
              esac
              ;;
            codex)
              case "$agent_name:$agent_command" in
                codex:*|*:*@openai/codex*) agent_match=true ;;
              esac
              ;;
          esac
          if [ "$agent_match" = true ]; then
            agent_pgid=$(/bin/ps -o pgid= -p "$agent_pid" 2>/dev/null | /usr/bin/tr -d ' ')
            break
          fi
          parent_pid=$(/bin/ps -o ppid= -p "$agent_pid" 2>/dev/null | /usr/bin/tr -d ' ')
          case "$parent_pid" in
            ''|*[!0-9]*|"$agent_pid") break ;;
          esac
          agent_pid=$parent_pid
        done
        if [ -z "$agent_pgid" ]; then
          agent_pgid=$(/bin/ps -o pgid= -p $$ 2>/dev/null | /usr/bin/tr -d ' ')
        fi
        # These run on every tool call. The listener is on loopback in this machine's own
        # app, so a second of waiting means it is not there — and a hook that stalls is a
        # hook that slows the agent it is watching.
        /usr/bin/curl --silent --connect-timeout 1 --max-time 1 --output /dev/null \
          --request POST \
          --header "Authorization: Bearer ${TENON_AGENT_HOOK_TOKEN}" \
          --header "Content-Type: application/json" \
          --header "X-Tenon-Pane-ID: ${TENON_PANE_ID}" \
          --header "X-Tenon-Surface-Token: ${TENON_AGENT_SURFACE_TOKEN}" \
          --header "X-Tenon-Process-Group: ${agent_pgid}" \
          --header "X-Tenon-Agent-Provider: ${TENON_AGENT_PROVIDER}" \
          --data-binary @- \
          "http://127.0.0.1:${TENON_AGENT_HOOK_PORT}/v1/agent-events" \
          >/dev/null 2>&1 || :
        exit 0
        """
}
