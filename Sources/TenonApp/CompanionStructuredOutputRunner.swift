// @domain: companion
import Foundation
import TenonCore

/// Common execution edge for every host-owned AI helper. Tasks supply their bounded prompt
/// and schema; provider selection, CLI grammar, JSON channel, cwd, and process policy live here.
protocol CompanionStructuredOutputRunning: Sendable {
    func run(prompt: String, outputSchema: String) async throws -> Data
}

struct LiveCompanionStructuredOutputRunner: CompanionStructuredOutputRunning, Sendable {
    let profile: @MainActor @Sendable () -> CompanionProfile

    init(profile: @escaping @MainActor @Sendable () -> CompanionProfile) {
        self.profile = profile
    }

    @concurrent
    func run(prompt: String, outputSchema: String) async throws -> Data {
        let profile = await profile()
        let executables = await AgentExecutableLocator.scanLive()
        guard let executableURL = executables[profile.agent] else {
            throw CompanionTaskFailure.unavailable
        }
        try Task.checkCancellation()

        let workingDirectoryURL = try Self.workingDirectory(for: profile)
        let effectivePrompt = Self.composedPrompt(
            taskPrompt: prompt,
            customPrompt: profile.customPromptArgument
        )
        switch profile.agent {
        case .claude:
            let output = try await CompanionClaudeAdapter.run(
                executableURL: executableURL,
                model: profile.modelArgument,
                prompt: effectivePrompt,
                outputSchema: outputSchema,
                workingDirectoryURL: workingDirectoryURL
            )
            return try CompanionClaudeAdapter.structuredOutput(from: output.stdout)
        case .codex:
            let output = try await CompanionCodexAdapter.run(
                executableURL: executableURL,
                model: profile.modelArgument,
                prompt: effectivePrompt,
                outputSchema: outputSchema,
                workingDirectoryURL: workingDirectoryURL
            )
            return try CompanionCodexAdapter.structuredOutput(from: output.stdout)
        }
    }

    static func composedPrompt(taskPrompt: String, customPrompt: String?) -> String {
        guard let customPrompt else { return taskPrompt }
        return """
        The user configured these Companion preferences. Follow them when they do not
        conflict with the task, safety boundary, or output schema:
        --- BEGIN COMPANION PREFERENCES ---
        \(customPrompt)
        --- END COMPANION PREFERENCES ---

        \(taskPrompt)
        """
    }

    private static func workingDirectory(for profile: CompanionProfile) throws -> URL {
        let configured = profile.workingDirectory
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configured.isEmpty else {
            return FileManager.default.temporaryDirectory
        }
        guard let requested = profile.workingDirectoryURL else {
            throw CompanionTaskFailure.invalidWorkingDirectory(configured)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: requested.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue
        else { throw CompanionTaskFailure.invalidWorkingDirectory(requested.path) }
        return requested
    }
}

enum CompanionClaudeAdapter {
    static func arguments(model: String?, outputSchema: String) -> [String] {
        var result = ["-p"]
        if let model { result += ["--model", model] }
        result += [
            "--output-format", "json",
            "--json-schema", outputSchema,
            "--max-turns", "1",
            "--safe-mode",
            "--no-session-persistence",
            "--tools", "",
        ]
        return result
    }

    static func run(
        executableURL: URL,
        model: String?,
        prompt: String,
        outputSchema: String,
        workingDirectoryURL: URL
    ) async throws -> CompanionProcessOutput {
        try await CompanionProcessRunner.run(
            executableURL: executableURL,
            arguments: arguments(model: model, outputSchema: outputSchema),
            prompt: prompt,
            workingDirectoryURL: workingDirectoryURL
        )
    }

    static func structuredOutput(from data: Data) throws -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { throw CompanionTaskFailure.malformedOutput }

        let payload: Any
        if let structured = dictionary["structured_output"] {
            payload = structured
        } else if let result = dictionary["result"] as? [String: Any] {
            payload = result
        } else if let result = dictionary["result"] as? String,
                  let nestedData = result.data(using: .utf8),
                  let nested = try? JSONSerialization.jsonObject(with: nestedData)
        {
            payload = nested
        } else {
            payload = dictionary
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let canonical = try? JSONSerialization.data(
                  withJSONObject: payload,
                  options: [.sortedKeys]
              )
        else { throw CompanionTaskFailure.malformedOutput }
        return canonical
    }
}

enum CompanionCodexAdapter {
    static func arguments(model: String?, schemaURL: URL) -> [String] {
        var result = ["exec"]
        if let model { result += ["--model", model] }
        result += [
            "--sandbox", "read-only",
            "--ephemeral",
            "--ignore-rules",
            "--skip-git-repo-check",
            "--json",
            "--output-schema", schemaURL.path,
            "-",
        ]
        return result
    }

    static func run(
        executableURL: URL,
        model: String?,
        prompt: String,
        outputSchema: String,
        workingDirectoryURL: URL
    ) async throws -> CompanionProcessOutput {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tenon-companion-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let schemaURL = directory.appendingPathComponent("output-schema.json")
        try Data(outputSchema.utf8).write(to: schemaURL, options: .atomic)
        return try await CompanionProcessRunner.run(
            executableURL: executableURL,
            arguments: arguments(model: model, schemaURL: schemaURL),
            prompt: prompt,
            workingDirectoryURL: workingDirectoryURL
        )
    }

    /// Codex's machine-readable channel is JSONL. Only the final `agent_message` item may
    /// carry task output; terminal rendering, stderr, and progress objects are never results.
    static func structuredOutput(from data: Data) throws -> Data {
        var candidate: Data?
        for line in data.split(separator: 0x0A) {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line))
                    as? [String: Any],
                  event["type"] as? String == "item.completed",
                  let item = event["item"] as? [String: Any],
                  item["type"] as? String == "agent_message",
                  let text = item["text"] as? String,
                  let payload = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: payload),
                  JSONSerialization.isValidJSONObject(object)
            else { continue }
            candidate = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
        }
        guard let candidate else { throw CompanionTaskFailure.malformedOutput }
        return candidate
    }
}
