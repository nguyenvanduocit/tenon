// @domain: agent-lens
import Foundation
import TenonCore

enum AgentCLI: String, CaseIterable, Hashable, Sendable {
    case codex
    case claude

    var label: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        }
    }

    var executableName: String { rawValue }
}

/// One ephemeral, machine-local launcher choice. The executable path and the small
/// allowlisted argument list live in memory only; raw shell history is never retained.
struct AgentLaunchSuggestion: Identifiable, Equatable, Sendable {
    let agent: AgentCLI
    let executableURL: URL
    let arguments: [String]

    var id: AgentCLI { agent }

    var habitDescription: String? {
        switch agent {
        case .codex:
            if arguments.contains("--dangerously-bypass-approvals-and-sandbox") {
                return "Bypass approvals"
            }
            if arguments.contains("--full-auto") { return "Full auto" }
            if let value = value(after: "--model") { return "Model \(value)" }
            if let value = value(after: "--profile") { return "Profile \(value)" }
            if let value = value(after: "--sandbox") {
                return value.replacingOccurrences(of: "-", with: " ").capitalized
            }
            if let value = value(after: "--ask-for-approval") {
                return "Approval: \(value)"
            }

        case .claude:
            if arguments.contains("--dangerously-skip-permissions") {
                return "Skip permissions"
            }
            if value(after: "--permission-mode") == "bypassPermissions" {
                return "Bypass permissions"
            }
            if arguments.contains("--allow-dangerously-skip-permissions") {
                return "Bypass available"
            }
            if let value = value(after: "--model") { return "Model \(value)" }
            if let value = value(after: "--effort") { return "Effort: \(value)" }
            if let value = value(after: "--permission-mode") {
                return "Permissions: \(value)"
            }
        }
        return arguments.isEmpty ? nil : "Recent options"
    }

    var displayCommand: String {
        ([agent.executableName] + arguments).joined(separator: " ")
    }

    var commandLine: String {
        ([executableURL.path] + arguments)
            .map(AutomationAuthoring.posixQuoted)
            .joined(separator: " ")
    }

    private func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }
}

/// Detects host-supported coding agents without starting a shell. Reading is deliberately
/// bounded and performed from a detached utility task so app launch and SwiftUI stay free
/// of filesystem work.
struct AgentLaunchDetector: Sendable {
    static let maximumHistoryBytesPerFile = 512 * 1_024
    static let maximumNVMVersions = 20

    let environment: [String: String]
    let homeDirectory: URL
    let executableDirectories: [URL]?
    let historyFileURLs: [URL]?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        executableDirectories: [URL]? = nil,
        historyFileURLs: [URL]? = nil
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.executableDirectories = executableDirectories
        self.historyFileURLs = historyFileURLs
    }

    static func scanLive() async -> [AgentLaunchSuggestion] {
        let detector = AgentLaunchDetector()
        return await Task.detached(priority: .utility) {
            detector.scan()
        }.value
    }

    func scan() -> [AgentLaunchSuggestion] {
        let fileManager = FileManager.default
        let history = resolvedHistoryFiles()
            .compactMap { Self.readTail(of: $0) }
            .joined(separator: "\n")

        return AgentCLI.allCases.compactMap { agent in
            guard let executableURL = executableURL(for: agent, fileManager: fileManager)
            else { return nil }
            return AgentLaunchSuggestion(
                agent: agent,
                executableURL: executableURL,
                arguments: AgentLaunchHistory.preferredArguments(
                    for: agent,
                    in: history
                )
            )
        }
    }

    private func executableURL(
        for agent: AgentCLI,
        fileManager: FileManager
    ) -> URL? {
        for directory in resolvedExecutableDirectories(fileManager: fileManager) {
            let candidate = directory.appendingPathComponent(agent.executableName)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: candidate.path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue,
                fileManager.isExecutableFile(atPath: candidate.path)
            else { continue }
            return candidate.standardizedFileURL
        }
        return nil
    }

    private func resolvedExecutableDirectories(fileManager: FileManager) -> [URL] {
        if let executableDirectories {
            return Self.unique(executableDirectories)
        }

        var directories = environment["PATH", default: ""]
            .split(separator: ":")
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }

        for path in [
            ".local/bin",
            ".npm-global/bin",
            ".local/share/pnpm",
            ".bun/bin",
            ".volta/bin",
            ".asdf/shims",
            ".local/share/mise/shims",
            "bin",
        ] {
            directories.append(
                homeDirectory.appendingPathComponent(path, isDirectory: true)
            )
        }
        directories.append(URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true))
        directories.append(URL(fileURLWithPath: "/usr/local/bin", isDirectory: true))
        directories.append(URL(fileURLWithPath: "/usr/bin", isDirectory: true))

        let nvmRoot = homeDirectory.appendingPathComponent(
            ".nvm/versions/node",
            isDirectory: true
        )
        if let versions = try? fileManager.contentsOfDirectory(
            at: nvmRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            directories.append(contentsOf: versions
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
                .prefix(Self.maximumNVMVersions)
                .map { $0.appendingPathComponent("bin", isDirectory: true) })
        }

        return Self.unique(directories)
    }

    private func resolvedHistoryFiles() -> [URL] {
        if let historyFileURLs { return Self.unique(historyFileURLs) }

        var files = [
            homeDirectory.appendingPathComponent(".zsh_history"),
            homeDirectory.appendingPathComponent(".bash_history"),
            homeDirectory.appendingPathComponent(".local/share/fish/fish_history"),
        ]
        if let configured = environment["HISTFILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            if configured == "~" {
                files.append(homeDirectory)
            } else if configured.hasPrefix("~/") {
                files.append(
                    homeDirectory.appendingPathComponent(String(configured.dropFirst(2)))
                )
            } else if configured.hasPrefix("/") {
                files.append(URL(fileURLWithPath: configured))
            } else {
                files.append(homeDirectory.appendingPathComponent(configured))
            }
        }
        return Self.unique(files)
    }

    private static func readTail(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(maximumHistoryBytesPerFile)
            ? end - UInt64(maximumHistoryBytesPerFile)
            : 0
        do {
            try handle.seek(toOffset: start)
            guard var data = try handle.read(upToCount: maximumHistoryBytesPerFile),
                  !data.isEmpty
            else { return nil }
            if start > 0, let newline = data.firstIndex(of: 0x0A) {
                data.removeSubrange(data.startIndex...newline)
            }
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var paths: Set<String> = []
        return urls.compactMap { url in
            let standardized = url.standardizedFileURL
            return paths.insert(standardized.path).inserted ? standardized : nil
        }
    }
}

enum AgentLaunchHistory {
    static func preferredArguments(
        for agent: AgentCLI,
        in history: String
    ) -> [String] {
        let invocations = history
            .split(whereSeparator: \Character.isNewline)
            .compactMap { invocation(in: String($0), for: agent) }
        guard let latestIndex = invocations.indices.last else { return [] }

        struct Habit {
            var arguments: [String]
            var count: Int
            var lastIndex: Int
        }
        var habits: [String: Habit] = [:]
        for (index, arguments) in invocations.enumerated() where !arguments.isEmpty {
            let key = arguments.joined(separator: "\u{1F}")
            if var habit = habits[key] {
                habit.count += 1
                habit.lastIndex = index
                habits[key] = habit
            } else {
                habits[key] = Habit(arguments: arguments, count: 1, lastIndex: index)
            }
        }
        guard let preferred = habits.values.max(by: { lhs, rhs in
            lhs.count == rhs.count
                ? lhs.lastIndex < rhs.lastIndex
                : lhs.count < rhs.count
        }) else { return [] }

        // One explicit current choice is useful; an older one-off is not a habit. Older
        // options must therefore repeat before Tenon carries them into a new session.
        guard preferred.lastIndex == latestIndex || preferred.count >= 2 else { return [] }
        return preferred.arguments
    }

    private static func invocation(in historyLine: String, for agent: AgentCLI) -> [String]? {
        var line = historyLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix(": "), let separator = line.firstIndex(of: ";") {
            line = String(line[line.index(after: separator)...])
        } else if line.hasPrefix("- cmd: ") {
            line = String(line.dropFirst(7))
        } else if line.hasPrefix("cmd: ") {
            line = String(line.dropFirst(5))
        }

        guard let words = shellWords(line), !words.isEmpty else { return nil }
        var index = 0
        while words.indices.contains(index), isEnvironmentAssignment(words[index]) {
            index += 1
        }
        if words.indices.contains(index), words[index] == "command" { index += 1 }
        if words.indices.contains(index), words[index] == "env" {
            index += 1
            while words.indices.contains(index), isEnvironmentAssignment(words[index]) {
                index += 1
            }
        }
        guard words.indices.contains(index),
              URL(fileURLWithPath: words[index]).lastPathComponent == agent.executableName
        else { return nil }
        return allowedArguments(Array(words.dropFirst(index + 1)), for: agent)
    }

    private static func allowedArguments(_ words: [String], for agent: AgentCLI) -> [String] {
        let policy = flagPolicy(for: agent)
        var result: [String] = []
        var index = 0
        while words.indices.contains(index) {
            let word = words[index]
            if word == "--" || !word.hasPrefix("-") { break }

            if let separator = word.firstIndex(of: "=") {
                let flag = String(word[..<separator])
                let value = String(word[word.index(after: separator)...])
                if let canonical = policy.values[flag], isSafeValue(value) {
                    result += [canonical, value]
                }
                index += 1
                continue
            }
            if let canonical = policy.booleans[word] {
                if !result.contains(canonical) { result.append(canonical) }
                index += 1
                continue
            }
            if let canonical = policy.values[word],
               words.indices.contains(index + 1),
               isSafeValue(words[index + 1]) {
                result += [canonical, words[index + 1]]
                index += 2
                continue
            }
            index += 1
        }
        return result
    }

    private static func flagPolicy(
        for agent: AgentCLI
    ) -> (booleans: [String: String], values: [String: String]) {
        switch agent {
        case .codex:
            return (
                [
                    "--dangerously-bypass-approvals-and-sandbox":
                        "--dangerously-bypass-approvals-and-sandbox",
                    "--dangerously-bypass-hook-trust": "--dangerously-bypass-hook-trust",
                    "--full-auto": "--full-auto",
                    "--no-alt-screen": "--no-alt-screen",
                    "--oss": "--oss",
                    "--search": "--search",
                    "--strict-config": "--strict-config",
                ],
                [
                    "-m": "--model", "--model": "--model",
                    "-p": "--profile", "--profile": "--profile",
                    "-s": "--sandbox", "--sandbox": "--sandbox",
                    "-a": "--ask-for-approval", "--ask-for-approval": "--ask-for-approval",
                    "--local-provider": "--local-provider",
                ]
            )

        case .claude:
            return (
                [
                    "--allow-dangerously-skip-permissions":
                        "--allow-dangerously-skip-permissions",
                    "--dangerously-skip-permissions": "--dangerously-skip-permissions",
                    "--bare": "--bare",
                    "--brief": "--brief",
                    "--chrome": "--chrome",
                    "--ide": "--ide",
                    "--no-chrome": "--no-chrome",
                    "--safe-mode": "--safe-mode",
                    "--verbose": "--verbose",
                ],
                [
                    "--agent": "--agent",
                    "--autocompact": "--autocompact",
                    "--effort": "--effort",
                    "--model": "--model",
                    "--permission-mode": "--permission-mode",
                    "--prompt-suggestions": "--prompt-suggestions",
                ]
            )
        }
    }

    private static func isEnvironmentAssignment(_ word: String) -> Bool {
        guard let separator = word.firstIndex(of: "="), separator != word.startIndex else {
            return false
        }
        let name = word[..<separator]
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private static func isSafeValue(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 120 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45...58, 64...90, 95, 97...122:
                true
            default:
                false
            }
        }
    }

    /// Enough shell tokenization to recognize one direct invocation. Operators are
    /// rejected, because a chained history entry is not one launch preference.
    private static func shellWords(_ line: String) -> [String]? {
        enum Quote { case none, single, double }
        let characters = Array(line)
        var quote = Quote.none
        var escaping = false
        var current = ""
        var words: [String] = []

        func appendCurrent() {
            guard !current.isEmpty else { return }
            words.append(current)
            current = ""
        }

        for (index, character) in characters.enumerated() {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            switch quote {
            case .single:
                if character == "'" { quote = .none } else { current.append(character) }

            case .double:
                if character == "\"" {
                    quote = .none
                } else if character == "\\" {
                    escaping = true
                } else if character == "$",
                          characters.indices.contains(index + 1),
                          characters[index + 1] == "(" {
                    return nil
                } else {
                    current.append(character)
                }

            case .none:
                if character.isWhitespace {
                    appendCurrent()
                } else if character == "'" {
                    quote = .single
                } else if character == "\"" {
                    quote = .double
                } else if character == "\\" {
                    escaping = true
                } else if ";|&<>`".contains(character) {
                    return nil
                } else if character == "$",
                          characters.indices.contains(index + 1),
                          characters[index + 1] == "(" {
                    return nil
                } else {
                    current.append(character)
                }
            }
        }
        guard quote == .none, !escaping else { return nil }
        appendCurrent()
        return words
    }
}

enum AgentLaunchPlacement: Equatable {
    case newTab
    case tab(UUID)
    case emptyTab
    case emptySlot(UUID)
    case emptyGrid(GridRect)
}

/// Host-native placement and terminal delivery. This is the same typed workspace/surface
/// path used by personal runbooks; it never mints a principal or enters the intent adapter.
@MainActor
enum AgentLaunchExecutor {
    static func run(
        _ suggestion: AgentLaunchSuggestion,
        placement: AgentLaunchPlacement,
        workspaceStore: WorkspaceStore,
        terminalPool: SurfacePool
    ) -> LauncherOutcome {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: suggestion.executableURL.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue,
            fileManager.isExecutableFile(atPath: suggestion.executableURL.path)
        else { return .agentUnavailable }

        guard let workspace = workspaceStore.catalog.activeWorkspace else {
            return .targetUnavailable
        }
        let paneID: UUID?
        switch placement {
        case .newTab:
            let existingTabs = Set(workspace.tabs.map(\.id))
            workspaceStore.newTab(content: .terminal)
            guard let tab = workspaceStore.catalog.activeTab,
                  !existingTabs.contains(tab.id)
            else { return .targetUnavailable }
            paneID = tab.activeSlotID

        case .tab(let tabID):
            guard workspace.tabs.contains(where: { $0.id == tabID }) else {
                return .targetUnavailable
            }
            workspaceStore.selectTab(tabID)
            if let empty = workspaceStore.catalog.activeTab?.slots.first(where: {
                $0.content == .empty
            }) {
                workspaceStore.setSlotContent(empty.id, .terminal)
                workspaceStore.focusSlot(empty.id)
                paneID = empty.id
            } else if workspaceStore.catalog.activeTab?.slots.isEmpty == true {
                workspaceStore.addSlot(content: .terminal)
                paneID = workspaceStore.catalog.activeSlotID
            } else {
                let existingPanes = Set(
                    workspaceStore.catalog.activeTab?.slots.map(\.id) ?? []
                )
                workspaceStore.splitActiveSlot(.horizontal, content: .terminal)
                let candidate = workspaceStore.catalog.activeSlotID
                paneID = candidate.flatMap { existingPanes.contains($0) ? nil : $0 }
            }

        case .emptyTab:
            guard workspaceStore.catalog.activeTab?.slots.isEmpty == true else {
                return .targetUnavailable
            }
            workspaceStore.addSlot(content: .terminal)
            paneID = workspaceStore.catalog.activeSlotID

        case .emptySlot(let slotID):
            guard workspaceStore.catalog.slot(id: slotID)?.content == .empty else {
                return .targetUnavailable
            }
            workspaceStore.setSlotContent(slotID, .terminal)
            workspaceStore.focusSlot(slotID)
            paneID = workspaceStore.catalog.slot(id: slotID)?.content == .terminal
                ? slotID
                : nil

        case .emptyGrid(let rect):
            paneID = workspaceStore.addSlot(content: .terminal, at: rect)
        }

        guard let paneID,
              workspaceStore.catalog.slot(id: paneID)?.content == .terminal
        else { return .targetUnavailable }
        terminalPool.seedSpawnDirectory(workspace.path, for: paneID)
        terminalPool.sendTextWhenReady(suggestion.commandLine + "\n", to: paneID)
        return .ran
    }
}
