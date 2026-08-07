import Foundation

/// How one Claude Code tool call reads to a human, and what its result says about the way
/// it ended. Both the transcript decoder and the hook projection ask this type, so a tool
/// named once is named the same wherever the fact arrives from — the transcript that
/// carries evidence offsets, or the hook that arrives while the call is still running.
///
/// Pure by construction: it reads the provider's own argument and result documents and
/// touches no filesystem, clock, or process.
enum ClaudeToolFacts {
    private static let detailLimit = 8 << 10
    private static let summaryLimit = 240

    struct Presentation: Equatable, Sendable {
        let name: String
        let kind: AgentToolKind
        let summary: String
    }

    struct Completion: Equatable, Sendable {
        let state: AgentToolState
        let detail: String
        let exitCode: Int?
    }

    struct Question: Equatable, Sendable {
        let header: String
        let prompt: String
        let options: [AgentInteractionOption]
    }

    /// `workspaceRoot` is the directory the provider reported for the call. Paths are shown
    /// relative to it when they sit inside, because "poc/Package.swift" is what a person
    /// recognizes and the absolute path is one inspector click away.
    static func presentation(
        toolName: String,
        input: [String: Any],
        workspaceRoot: String? = nil
    ) -> Presentation {
        let kind = self.kind(toolName: toolName, input: input)
        return Presentation(
            name: displayName(toolName: toolName, kind: kind, input: input),
            kind: kind,
            summary: summary(toolName: toolName, kind: kind, input: input, root: workspaceRoot)
        )
    }

    static func completion(toolName: String, response: Any?, isError: Bool) -> Completion {
        if let text = response as? String {
            let exitCode = self.exitCode(in: text)
            return Completion(
                state: isError || exitCode.map { $0 != 0 } == true ? .failed : .succeeded,
                detail: capped(text),
                exitCode: exitCode
            )
        }
        guard let object = response as? [String: Any] else {
            return Completion(state: isError ? .failed : .succeeded, detail: "", exitCode: nil)
        }
        if object["interrupted"] as? Bool == true {
            return Completion(state: .declined, detail: capped(shellOutput(object)), exitCode: nil)
        }
        if isError {
            return Completion(state: .failed, detail: capped(shellOutput(object)), exitCode: nil)
        }
        return Completion(
            state: object["success"] as? Bool == false ? .failed : .succeeded,
            detail: capped(resultDetail(toolName: toolName, object: object)),
            exitCode: nil
        )
    }

    static func questions(input: [String: Any]) -> [Question] {
        guard let raw = input["questions"] as? [[String: Any]] else { return [] }
        return raw.enumerated().map { index, question in
            let options = (question["options"] as? [[String: Any]] ?? [])
                .enumerated()
                .map { optionIndex, option in
                    AgentInteractionOption(
                        id: "\(index)-\(optionIndex)",
                        label: string(option["label"]) ?? "Option \(optionIndex + 1)",
                        detail: string(option["description"]) ?? ""
                    )
                }
            return Question(
                header: string(question["header"]) ?? "",
                prompt: string(question["question"]) ?? "",
                options: options
            )
        }
    }

    static func answers(response: Any?) -> [String] {
        guard let object = response as? [String: Any] else { return [] }
        if let answers = object["answers"] as? [String] { return answers }
        if let answers = object["answers"] as? [String: Any] {
            return answers.values.compactMap { string($0) }
        }
        return []
    }

    static func capped(_ value: String) -> String {
        guard value.utf8.count > detailLimit else { return value }
        return String(value.prefix(detailLimit)) + "…"
    }

    // MARK: - Classification

    private static func kind(toolName: String, input: [String: Any]) -> AgentToolKind {
        switch toolName {
        case "Bash", "BashOutput", "KillShell":
            .command
        case "Write", "Edit", "NotebookEdit", "MultiEdit":
            .fileChange
        case "Read", "NotebookRead":
            .fileRead
        case "Grep", "Glob", "LS":
            .search
        case "WebFetch", "WebSearch":
            .webSearch
        case "TodoWrite":
            .plan
        case "Skill":
            .skill
        case "Task", "Agent", "Workflow", "SendMessage":
            .subagent
        case "AskUserQuestion":
            .question
        default:
            input["command"] != nil ? .command : .generic
        }
    }

    private static func displayName(
        toolName: String,
        kind: AgentToolKind,
        input: [String: Any]
    ) -> String {
        switch kind {
        case .plan:
            "Plan"
        case .skill:
            string(input["skill"]) ?? string(input["command"]) ?? "Skill"
        case .question:
            "Question"
        default:
            toolName
        }
    }

    private static func summary(
        toolName: String,
        kind: AgentToolKind,
        input: [String: Any],
        root: String?
    ) -> String {
        let value: String
        switch toolName {
        case "Bash":
            value = string(input["command"]) ?? string(input["description"]) ?? ""
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit", "NotebookRead":
            value = path(input["file_path"] ?? input["notebook_path"], relativeTo: root)
        case "Grep":
            let pattern = string(input["pattern"]) ?? ""
            let scope = path(input["path"], relativeTo: root)
            value = scope.isEmpty ? pattern : "\(pattern) in \(scope)"
        case "Glob", "LS":
            value = string(input["pattern"]) ?? path(input["path"], relativeTo: root)
        case "WebFetch":
            value = string(input["url"]) ?? ""
        case "WebSearch":
            value = string(input["query"]) ?? ""
        case "Task", "Agent", "Workflow":
            value = string(input["description"]) ?? string(input["subagent_type"]) ?? ""
        case "TodoWrite":
            value = planSummary(input)
        case "Skill":
            value = string(input["args"]) ?? string(input["skill"]) ?? ""
        case "AskUserQuestion":
            value = questions(input: input).first?.prompt ?? ""
        default:
            value = string(input["description"])
                ?? string(input["command"])
                ?? string(input["query"])
                ?? ""
        }
        let normalized = value.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard normalized.count > summaryLimit else { return normalized }
        return String(normalized.prefix(summaryLimit)) + "…"
    }

    private static func planSummary(_ input: [String: Any]) -> String {
        guard let todos = input["todos"] as? [[String: Any]], !todos.isEmpty else {
            return "Execution checklist"
        }
        let completed = todos.filter { string($0["status"]) == "completed" }.count
        return "\(completed)/\(todos.count) steps complete"
    }

    // MARK: - Results

    private static func resultDetail(toolName: String, object: [String: Any]) -> String {
        if object["stdout"] != nil || object["stderr"] != nil {
            return shellOutput(object)
        }
        if let patch = object["structuredPatch"] as? [[String: Any]] {
            let counts = patchCounts(patch)
            let changed = counts.added > 0 || counts.removed > 0
                ? "+\(counts.added) −\(counts.removed)"
                : "no textual change"
            let kind = string(object["type"]) == "create" ? "Created" : "Edited"
            return "\(kind) \(URL(fileURLWithPath: string(object["filePath"]) ?? "").lastPathComponent) · \(changed)"
        }
        if let file = object["file"] as? [String: Any] {
            let lines = file["numLines"] as? Int
            let name = URL(fileURLWithPath: string(file["filePath"]) ?? "").lastPathComponent
            return lines.map { "Read \(name) · \($0) lines" } ?? "Read \(name)"
        }
        if let name = string(object["commandName"]) {
            return "Loaded \(name)"
        }
        if let answers = object["answers"] as? [String], !answers.isEmpty {
            return answers.joined(separator: " · ")
        }
        return ""
    }

    private static func shellOutput(_ object: [String: Any]) -> String {
        let stdout = string(object["stdout"]) ?? ""
        let stderr = string(object["stderr"]) ?? ""
        if stderr.isEmpty { return stdout }
        if stdout.isEmpty { return stderr }
        return stdout + "\n" + stderr
    }

    private static func patchCounts(_ patch: [[String: Any]]) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for hunk in patch {
            for line in hunk["lines"] as? [String] ?? [] {
                if line.hasPrefix("+") { added += 1 }
                if line.hasPrefix("-") { removed += 1 }
            }
        }
        return (added, removed)
    }

    /// Claude Code reports a failed call as prose that opens with its exit status.
    private static func exitCode(in text: String) -> Int? {
        guard let range = text.range(of: "Exit code ") else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    // MARK: - Values

    private static func path(_ value: Any?, relativeTo root: String?) -> String {
        guard let raw = string(value), !raw.isEmpty else { return "" }
        guard let root, !root.isEmpty else { return raw }
        let normalizedRoot = root.hasSuffix("/") ? root : root + "/"
        guard raw.hasPrefix(normalizedRoot) else { return raw }
        return String(raw.dropFirst(normalizedRoot.count))
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}
