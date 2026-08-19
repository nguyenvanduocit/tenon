// @domain: plugin-host, plugin-contributions
import Foundation
import TenonCore
import TenonIntentCore

struct ClaudeSessionRecord: Sendable, Equatable {
    enum Provider: String, Sendable {
        case claude
        case codex
        case opencode
    }

    let provider: Provider
    let id: String
    var path: String
    let mtime: Int
    let size: Int64
    var prompts: Int
    var replies: Int
    let tokens: Int
    var branch: String
    var title: String
}

struct ClaudeAgentRecord: Sendable, Equatable {
    let id: String
    let label: String
}

struct ClaudeFavouriteRecord: Sendable, Equatable {
    let key: String
    let project: String
    let at: Int
}

struct ClaudeSessionsPaneState: Sendable, Equatable {
    let id: String
    var workspaceID: String?
    var workspacePath = ""
    var project = ""
    var sessions: [ClaudeSessionRecord] = []
    var agents: [ClaudeAgentRecord] = []
    var notice = "Loading…"
    var scanError: String?
    var favouriteError: String?
    var generation: UInt64 = 0
}

struct ClaudeSessionsIntentCaller: Sendable {
    let send: @Sendable (IntentID, IntentValue) async -> IntentResult
}

struct ClaudeProviderScanResult: Sendable {
    let sessions: [ClaudeSessionRecord]
    let error: String?
}

enum ClaudeSessionsScan {
    static let maxListingPages = 32
    static let maxFavouriteLookup = 100

    /// The process body is deliberately the same bounded awk program as the JavaScript
    /// backend. It extracts only the fields the list renders, rather than returning whole
    /// transcript records through the finite process intent body.
    static let awk = #"""
FNR == 1 { if (f != "") emit(); f = FILENAME; p = 0; r = 0; t = ""; first = ""; branch = "" }
{ h = substr($0, 1, 1000) }
h ~ /"role":"user"/ && h !~ /"tool_use_id"/ { p++; if (first == "") first = jsonString($0, "content", 240); if (branch == "") branch = jsonString($0, "gitBranch", 100) }
h ~ /"role":"assistant"/ { r++ }
h ~ /[,{]"type":"ai-title"[,}]/ { t = jsonString($0, "aiTitle", 240) }
END { if (f != "") emit() }
function jsonString(line, key, maximum, marker, start, i, ch, escaped, out) { marker = "\"" key "\":\""; start = index(line, marker); if (!start) return ""; start += length(marker); escaped = 0; out = ""; for (i = start; i <= length(line) && length(out) < maximum; i++) { ch = substr(line, i, 1); if (ch == "\"" && !escaped) break; out = out ch; if (ch == "\\" && !escaped) escaped = 1; else escaped = 0 } if (escaped) out = substr(out, 1, length(out) - 1); return out }
function emit() { printf "%s\t%d\t%d\t%s\t%s\t%s\n", f, p, r, t, first, branch }
"""#

    private static let agentInventory = try! IntentID("agent.inventory.v1")
    private static let workspacePaneOwner = try! IntentID("workspace.pane.owner.v1")
    private static let directoryList = try! IntentID("filesystem.directory.list.v2")
    private static let processExec = try! IntentID("process.exec.v1")

    static func readFavourites(_ value: IntentValue?) -> [ClaudeFavouriteRecord] {
        guard case let .array(records)? = value else { return [] }
        return Array(records.prefix(200)).compactMap { value -> ClaudeFavouriteRecord? in
            guard case let .object(fields) = value,
                  let key = fields["key"]?.claudeStringValue,
                  !key.isEmpty,
                  let project = fields["project"]?.claudeStringValue,
                  !project.isEmpty
            else { return nil }
            return ClaudeFavouriteRecord(
                key: key,
                project: project,
                at: Int(fields["at"]?.claudeIntValue ?? 0)
            )
        }
    }

    static func favouriteKey(
        provider: ClaudeSessionRecord.Provider,
        sessionID: String
    ) -> String {
        "\(provider.rawValue):\(sessionID)"
    }

    static func favouriteIDs(
        _ favourites: [ClaudeFavouriteRecord],
        project: String,
        provider: ClaudeSessionRecord.Provider
    ) -> [String] {
        let prefix = "\(provider.rawValue):"
        return favourites.compactMap { record in
            guard record.project == project, record.key.hasPrefix(prefix) else { return nil }
            return String(record.key.dropFirst(prefix.count))
        }
    }

    static func isFavourite(
        _ favourites: [ClaudeFavouriteRecord],
        project: String,
        provider: ClaudeSessionRecord.Provider,
        sessionID: String
    ) -> Bool {
        let key = favouriteKey(provider: provider, sessionID: sessionID)
        return favourites.contains { $0.project == project && $0.key == key }
    }

    static func loadAgents(
        caller: ClaudeSessionsIntentCaller,
        log: @escaping @Sendable (String) async -> Void
    ) async -> [ClaudeAgentRecord] {
        let result = await caller.send(
            agentInventory,
            .object([:])
        )
        guard case let .success(success) = result,
              let agents = success.value.claudeObjectValue?["agents"]?.claudeArrayValue
        else {
            if case let .failure(failure) = result {
                await log("agent-sessions: could not list agents: \(failure.error.code.rawValue)")
            }
            return []
        }

        return agents.compactMap { value in
            guard let fields = value.claudeObjectValue,
                  let id = fields["id"]?.claudeStringValue,
                  !id.isEmpty,
                  let label = fields["label"]?.claudeStringValue,
                  !label.isEmpty
            else { return nil }
            return ClaudeAgentRecord(id: id, label: label)
        }
    }

    static func scanClaude(
        project: String,
        claudeHome: String,
        favourites: [ClaudeFavouriteRecord],
        limit: Int,
        caller: ClaudeSessionsIntentCaller,
        log: @escaping @Sendable (String) async -> Void
    ) async -> ClaudeProviderScanResult {
        let listing = await listClaudeTranscripts(
            project: project,
            claudeHome: claudeHome,
            caller: caller,
            log: log
        )
        var sessions = listing.sessions
        sessions.sort { $0.mtime > $1.mtime }
        let keepCount = min(limit, sessions.count)
        if sessions.count > keepCount {
            sessions = Array(sessions.prefix(keepCount)) + sessions.dropFirst(keepCount).filter {
                isFavourite(
                    favourites,
                    project: project,
                    provider: .claude,
                    sessionID: $0.id
                )
            }
        }
        if !sessions.isEmpty {
            await enrichClaude(
                sessions: &sessions,
                project: project,
                caller: caller,
                log: log
            )
        }
        return ClaudeProviderScanResult(sessions: sessions, error: listing.error)
    }

    static func scanCodex(
        project: String,
        codexHome: String,
        favourites: [ClaudeFavouriteRecord],
        limit: Int,
        caller: ClaudeSessionsIntentCaller,
        log: @escaping @Sendable (String) async -> Void
    ) async -> [ClaudeSessionRecord] {
        let sessions = await fetchCodex(
            project: project,
            codexHome: codexHome,
            filter: "",
            limit: limit,
            caller: caller,
            log: log
        )
        let seen = Set(sessions.map(\.id))
        var missing = favouriteIDs(favourites, project: project, provider: .codex)
            .filter { !seen.contains($0) }
        if missing.count > maxFavouriteLookup {
            await log(
                "agent-sessions: \(missing.count - maxFavouriteLookup) favourited Codex "
                    + "sessions past the \(maxFavouriteLookup) this scan looks up"
            )
            missing = Array(missing.prefix(maxFavouriteLookup))
        }
        guard !missing.isEmpty else { return sessions }
        let marked = await fetchCodex(
            project: project,
            codexHome: codexHome,
            filter: codexIDFilter(missing),
            limit: missing.count,
            caller: caller,
            log: log
        )
        return sessions + marked
    }

    static func transcriptPath(
        for session: ClaudeSessionRecord,
        codexHome: String,
        project: String,
        caller: ClaudeSessionsIntentCaller
    ) async -> String {
        guard session.provider == .codex else { return session.path }
        let script = "exec /usr/bin/find \(shellPath(codexHome))/sessions "
            + "-maxdepth 5 -type f -name \"*$1.jsonl\" -print -quit"
        let result = await exec(
            command: "/bin/sh",
            arguments: ["-c", script, "tenon-codex-transcript", session.id],
            workingDirectory: project,
            caller: caller
        )
        guard result.ok, result.status == 0 else { return "" }
        return result.stdout.split(separator: "\n", maxSplits: 1).first
            .map(String.init) ?? ""
    }

    static func scanOpenCode(
        project: String,
        opencodeHome: String,
        favourites: [ClaudeFavouriteRecord],
        limit: Int,
        caller: ClaudeSessionsIntentCaller,
        log: @escaping @Sendable (String) async -> Void
    ) async -> [ClaudeSessionRecord] {
        let dbPath = opencodeHome.trimmingTrailingSlashes + "/opencode.db"
        let sessions = await fetchOpenCode(
            dbPath: dbPath,
            project: project,
            filter: "",
            limit: limit,
            caller: caller,
            log: log
        )
        let seen = Set(sessions.map(\.id))
        var missing = favouriteIDs(favourites, project: project, provider: .opencode)
            .filter { !seen.contains($0) }
        if missing.count > maxFavouriteLookup {
            await log(
                "agent-sessions: \(missing.count - maxFavouriteLookup) favourited opencode "
                    + "sessions past the \(maxFavouriteLookup) this scan looks up"
            )
            missing = Array(missing.prefix(maxFavouriteLookup))
        }
        guard !missing.isEmpty else { return sessions }
        let marked = await fetchOpenCode(
            dbPath: dbPath,
            project: project,
            filter: codexIDFilter(missing),
            limit: missing.count,
            caller: caller,
            log: log
        )
        return sessions + marked
    }

    static func owningWorkspace(
        instanceID: String,
        caller: ClaudeSessionsIntentCaller
    ) async -> (id: String?, path: String) {
        let result = await caller.send(
            workspacePaneOwner,
            .object(["paneID": .string(instanceID)])
        )
        guard case let .success(success) = result,
              let fields = success.value.claudeObjectValue
        else { return (nil, "") }
        return (
            fields["workspaceID"]?.claudeStringValue,
            fields["workspacePath"]?.claudeStringValue ?? ""
        )
    }

    static func sessionsDirectory(project: String, claudeHome: String) -> String {
        let slug = project.unicodeScalars.map { scalar in
            let isASCIIAlphaNumeric = scalar.value >= 48 && scalar.value <= 57
                || scalar.value >= 65 && scalar.value <= 90
                || scalar.value >= 97 && scalar.value <= 122
            return isASCIIAlphaNumeric ? String(scalar) : "-"
        }.joined()
        return claudeHome.trimmingTrailingSlashes + "/projects/" + slug
    }

    private static func listClaudeTranscripts(
        project: String,
        claudeHome: String,
        caller: ClaudeSessionsIntentCaller,
        log: @escaping @Sendable (String) async -> Void
    ) async -> ClaudeProviderScanResult {
        for attempt in 0 ..< 2 {
            var found: [ClaudeSessionRecord] = []
            var directory = ""
            var cursor: String?
            var stale = false

            for _ in 0 ..< maxListingPages {
                var input: [String: IntentValue] = [
                    "path": .string(sessionsDirectory(project: project, claudeHome: claudeHome)),
                    "limit": .integer(256),
                    "includeMetadata": .bool(true),
                ]
                if let cursor { input["cursor"] = .string(cursor) }
                let result = await caller.send(
                    directoryList,
                    .object(input)
                )
                guard case let .success(success) = result else {
                    guard case let .failure(failure) = result else {
                        return ClaudeProviderScanResult(sessions: [], error: nil)
                    }
                    if failure.error.code.rawValue == "dev.tenon.core.path-not-found" {
                        return ClaudeProviderScanResult(sessions: [], error: nil)
                    }
                    let reason = failure.error.details?.claudeObjectValue?["reason"]?.claudeStringValue
                    if reason == "stale-cursor", attempt == 0 {
                        stale = true
                        break
                    }
                    let failureText = reason ?? failure.error.code.rawValue
                    await log("agent-sessions: could not read Claude sessions: \(failureText)")
                    return ClaudeProviderScanResult(
                        sessions: [],
                        error: "Could not read Claude sessions: \(failureText)"
                    )
                }

                let fields = success.value.claudeObjectValue ?? [:]
                if directory.isEmpty { directory = fields["path"]?.claudeStringValue ?? "" }
                for value in fields["entries"]?.claudeArrayValue ?? [] {
                    guard let entry = value.claudeObjectValue,
                          entry["isDirectory"]?.claudeBoolValue != true,
                          let name = entry["name"]?.claudeStringValue,
                          name.hasSuffix(".jsonl"),
                          name.count > 6
                    else { continue }
                    let modifiedAt = entry["modifiedAt"]?.claudeStringValue
                        .flatMap { ISO8601DateFormatter().date(from: $0) }
                        .map { Int($0.timeIntervalSince1970) } ?? 0
                    found.append(
                        ClaudeSessionRecord(
                            provider: .claude,
                            id: String(name.dropLast(6)),
                            path: directory + "/" + name,
                            mtime: modifiedAt,
                            size: entry["sizeBytes"]?.claudeIntValue ?? 0,
                            prompts: 0,
                            replies: 0,
                            tokens: 0,
                            branch: "",
                            title: ""
                        )
                    )
                }
                cursor = fields["nextCursor"]?.claudeStringValue
                if cursor == nil { break }
            }
            if !stale { return ClaudeProviderScanResult(sessions: found, error: nil) }
        }
        return ClaudeProviderScanResult(sessions: [], error: nil)
    }

    private static func enrichClaude(
        sessions: inout [ClaudeSessionRecord],
        project: String,
        caller: ClaudeSessionsIntentCaller,
        log: @escaping @Sendable (String) async -> Void
    ) async {
        var byPath: [String: Int] = [:]
        for index in sessions.indices { byPath[sessions[index].path] = index }
        var offset = 0
        while offset < sessions.count {
            let end = min(sessions.count, offset + 25)
            var arguments = ["LC_ALL=C", "/usr/bin/awk", awk]
            arguments.append(contentsOf: sessions[offset ..< end].map(\.path))
            let result = await exec(
                command: "/usr/bin/env",
                arguments: arguments,
                workingDirectory: project,
                caller: caller
            )
            guard result.ok, result.status == 0 else {
                await log(
                    "agent-sessions: could not read Claude session details: "
                        + (result.error
                            ?? (result.stderr.isEmpty
                                ? "awk exited \(result.status)"
                                : result.stderr))
                )
                offset = end
                continue
            }
            for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count >= 6,
                      let index = byPath[String(fields[0])]
                else { continue }
                sessions[index].prompts = Int(fields[1]) ?? 0
                sessions[index].replies = Int(fields[2]) ?? 0
                sessions[index].title = cleanTitle(
                    decodeJSONFragment(String(fields[3]))
                )
                    ?? cleanTitle(decodeJSONFragment(String(fields[4])))
                    ?? ""
                sessions[index].branch = String(fields[5])
            }
            offset = end
        }
    }

    private static func fetchCodex(
        project: String,
        codexHome: String,
        filter: String,
        limit: Int,
        caller: ClaudeSessionsIntentCaller,
        log: @escaping @Sendable (String) async -> Void
    ) async -> [ClaudeSessionRecord] {
        let base = "SELECT id, "
            + "CASE WHEN recency_at > 0 THEN recency_at ELSE updated_at END AS mtime, "
            + "substr(COALESCE(NULLIF(trim(name), ''), NULLIF(trim(title), ''), "
            + "NULLIF(trim(first_user_message), ''), NULLIF(trim(preview), ''), ''), 1, 160) AS title, "
            + "tokens_used AS tokens, substr(COALESCE(git_branch, ''), 1, 80) AS branch "
            + "FROM threads WHERE archived = 0 AND source = 'cli' AND cwd = "
            + sqlString(project) + filter
            + " ORDER BY mtime DESC, id DESC LIMIT \(limit)"
        var result = await runCodexQuery(
            codexHome: codexHome,
            project: project,
            query: base,
            caller: caller
        )
        if !result.ok || result.status != 0 {
            let fallback = "SELECT id, updated_at AS mtime, "
                + "substr(COALESCE(title, ''), 1, 160) AS title, "
                + "tokens_used AS tokens, substr(COALESCE(git_branch, ''), 1, 80) AS branch "
                + "FROM threads WHERE archived = 0 AND source = 'cli' AND cwd = "
                + sqlString(project) + filter
                + " ORDER BY updated_at DESC, id DESC LIMIT \(limit)"
            result = await runCodexQuery(
                codexHome: codexHome,
                project: project,
                query: fallback,
                caller: caller
            )
        }
        guard result.ok, result.status == 0 else { return [] }
        guard let data = result.stdout.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return ClaudeSessionRecord(
                provider: .codex,
                id: id,
                path: "",
                mtime: integer(row["mtime"]),
                size: 0,
                prompts: 0,
                replies: 0,
                tokens: integer(row["tokens"]),
                branch: String(row["branch"] as? String ?? ""),
                title: cleanTitle(String(row["title"] as? String ?? "")) ?? ""
            )
        }
    }

    private static func runCodexQuery(
        codexHome: String,
        project: String,
        query: String,
        caller: ClaudeSessionsIntentCaller
    ) async -> ClaudeProcessResult {
        let script = "exec /usr/bin/sqlite3 -readonly -json \(shellPath(codexHome)) "
            + "\"$1\""
        return await exec(
            command: "/bin/sh",
            arguments: ["-c", script, "tenon-codex-scan", query],
            workingDirectory: project,
            caller: caller
        )
    }

    private static func fetchOpenCode(
        dbPath: String,
        project: String,
        filter: String,
        limit: Int,
        caller: ClaudeSessionsIntentCaller,
        log: @escaping @Sendable (String) async -> Void
    ) async -> [ClaudeSessionRecord] {
        let base = "SELECT id, (time_updated / 1000) AS mtime, "
            + "substr(COALESCE(NULLIF(trim(title), ''), ''), 1, 160) AS title, "
            + "(tokens_input + tokens_output + tokens_reasoning) AS tokens "
            + "FROM session WHERE time_archived IS NULL AND directory = "
            + sqlString(project) + filter
            + " ORDER BY time_updated DESC, id DESC LIMIT \(limit)"
        let result = await runOpenCodeQuery(
            dbPath: dbPath,
            project: project,
            query: base,
            caller: caller
        )
        guard result.ok, result.status == 0 else {
            if !result.ok || result.status != 0 {
                await log(
                    "agent-sessions: could not read opencode sessions: "
                        + (result.error ?? result.stderr)
                )
            }
            return []
        }
        guard let data = result.stdout.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return ClaudeSessionRecord(
                provider: .opencode,
                id: id,
                path: dbPath,
                mtime: integer(row["mtime"]),
                size: 0,
                prompts: 0,
                replies: 0,
                tokens: integer(row["tokens"]),
                branch: "",
                title: cleanTitle(String(row["title"] as? String ?? "")) ?? ""
            )
        }
    }

    private static func runOpenCodeQuery(
        dbPath: String,
        project: String,
        query: String,
        caller: ClaudeSessionsIntentCaller
    ) async -> ClaudeProcessResult {
        let script = "exec /usr/bin/sqlite3 -readonly -json \(shellPath(dbPath)) "
            + "\"$1\""
        return await exec(
            command: "/bin/sh",
            arguments: ["-c", script, "tenon-opencode-scan", query],
            workingDirectory: project,
            caller: caller
        )
    }

    private static func codexIDFilter(_ ids: [String]) -> String {
        " AND id IN (" + ids.map(sqlString).joined(separator: ", ") + ")"
    }

    private static func exec(
        command: String,
        arguments: [String],
        workingDirectory: String,
        caller: ClaudeSessionsIntentCaller
    ) async -> ClaudeProcessResult {
        let result = await caller.send(
            processExec,
            .object([
                "command": .string(command),
                "arguments": .array(arguments.map(IntentValue.string)),
                "workingDirectory": .string(workingDirectory.isEmpty ? "/" : workingDirectory),
            ])
        )
        guard case let .success(success) = result,
              let fields = success.value.claudeObjectValue
        else {
            let error: String? = if case let .failure(failure) = result {
                failure.error.code.rawValue
            } else {
                nil
            }
            return ClaudeProcessResult(ok: false, status: -1, stdout: "", stderr: "", error: error)
        }
        return ClaudeProcessResult(
            ok: true,
            status: Int(fields["exitCode"]?.claudeIntValue ?? -1),
            stdout: fields["standardOutput"]?.claudeObjectValue?["text"]?.claudeStringValue ?? "",
            stderr: fields["standardError"]?.claudeObjectValue?["text"]?.claudeStringValue ?? "",
            error: nil
        )
    }

    private static func shellPath(_ path: String) -> String {
        let quote = { (value: String) in "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        if path == "~" { return "\"$HOME\"" }
        if path.hasPrefix("~/") { return "\"$HOME\"/" + quote(String(path.dropFirst(2))) }
        return quote(path)
    }

    private static func sqlString(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\0", with: "").replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func cleanTitle(_ content: String) -> String? {
        var value = content
        if let nameStart = value.range(of: "<command-name>"),
           let nameEnd = value.range(of: "</command-name>", range: nameStart.upperBound ..< value.endIndex)
        {
            let name = String(value[nameStart.upperBound ..< nameEnd.lowerBound])
            var args = ""
            if let argsStart = value.range(of: "<command-args>"),
               let argsEnd = value.range(of: "</command-args>", range: argsStart.upperBound ..< value.endIndex)
            {
                args = String(value[argsStart.upperBound ..< argsEnd.lowerBound])
            }
            value = name + (args.isEmpty ? "" : " " + args)
        }
        value = value
            .replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return value.count > 90 ? String(value.prefix(90)) + "…" : value
    }

    private static func decodeJSONFragment(_ text: String) -> String {
        var candidate = text
        while !candidate.isEmpty {
            if let data = "\"\(candidate)\"".data(using: .utf8),
               let value = try? JSONSerialization.jsonObject(
                   with: data,
                   options: [.fragmentsAllowed]
               ) as? String
            {
                return value
            }
            candidate.removeLast()
        }
        return ""
    }

    private static func integer(_ value: Any?) -> Int {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }
}

private struct ClaudeProcessResult: Sendable {
    let ok: Bool
    let status: Int
    let stdout: String
    let stderr: String
    let error: String?
}

private extension String {
    var trimmingTrailingSlashes: String {
        var value = self
        while value.count > 1, value.last == "/" { value.removeLast() }
        return value
    }
}

private extension IntentValue {
    var claudeObjectValue: [String: IntentValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var claudeArrayValue: [IntentValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var claudeStringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var claudeBoolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    var claudeIntValue: Int64? {
        switch self {
        case let .integer(value): return value
        case let .number(value): return Int64(value)
        case let .string(value): return Int64(value)
        default: return nil
        }
    }
}
