// @domain: command-surface
import Foundation
import Observation
import TenonCore

enum QuickCommandRunner: String, CaseIterable, Codable, Sendable {
    case terminal
    case codex
    case claude

    var label: String {
        switch self {
        case .terminal: "Terminal"
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }

    var isAgent: Bool { self != .terminal }

    var executable: String? {
        switch self {
        case .terminal: nil
        case .codex: "codex"
        case .claude: "claude"
        }
    }
}

enum QuickCommandDestination: String, CaseIterable, Codable, Sendable {
    case focusedTerminal
    case newTab
}

enum QuickCommandScope: Equatable, Sendable {
    case global
    case project(path: String)

    var projectPath: String? {
        guard case let .project(path) = self else { return nil }
        return path
    }

    func includes(projectPath: String?) -> Bool {
        switch self {
        case .global:
            true
        case .project(let path):
            projectPath.map(Self.standardize) == Self.standardize(path)
        }
    }

    static func project(_ url: URL) -> Self {
        .project(path: standardize(url.path))
    }

    private static func standardize(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }
}

extension QuickCommandScope: Codable {
    private enum CodingKeys: String, CodingKey { case type, path }
    private enum Kind: String, Codable { case global, project }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(Kind.self, forKey: .type) ?? .global
        if kind == .project,
           let path = try container.decodeIfPresent(String.self, forKey: .path),
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self = .project(path: path)
        } else {
            self = .global
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .global:
            try container.encode(Kind.global, forKey: .type)
        case .project(let path):
            try container.encode(Kind.project, forKey: .type)
            try container.encode(path, forKey: .path)
        }
    }
}

struct QuickCommand: Identifiable, Equatable, Codable, Sendable {
    static let maximumCount = 40
    static let maximumLabelLength = 80
    static let maximumBodyLength = 6_000

    let id: UUID
    var label: String
    var runner: QuickCommandRunner
    var body: String
    var destination: QuickCommandDestination
    var appendEnter: Bool
    var scope: QuickCommandScope

    init(
        id: UUID = UUID(),
        label: String = "",
        runner: QuickCommandRunner = .terminal,
        body: String = "",
        destination: QuickCommandDestination = .focusedTerminal,
        appendEnter: Bool = true,
        scope: QuickCommandScope = .global
    ) {
        self.id = id
        self.label = label
        self.runner = runner
        self.body = body
        self.destination = destination
        self.appendEnter = appendEnter
        self.scope = scope
    }

    var isComplete: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var normalized: Self {
        var copy = self
        copy.label = String(
            label.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(Self.maximumLabelLength)
        )
        copy.body = String(body.prefix(Self.maximumBodyLength))
            .trimmingCharacters(in: .newlines)
        if copy.runner.isAgent {
            copy.destination = .newTab
        }
        if case let .project(path) = scope,
           path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.scope = .global
        }
        return copy
    }

    var subtitle: String {
        "\(runner.label) · \(body)"
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, runner, body, destination, appendEnter, scope
        // v1 migration: the first implementation stored action + agent separately.
        case action, agent
    }

    private enum LegacyAction: String, Codable {
        case terminalCommand
        case agentPrompt
    }

    private enum LegacyAgent: String, Codable {
        case codex
        case claude
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        body = try container.decode(String.self, forKey: .body)
        appendEnter = try container.decodeIfPresent(Bool.self, forKey: .appendEnter) ?? true
        scope = try container.decodeIfPresent(QuickCommandScope.self, forKey: .scope) ?? .global
        destination = try container.decodeIfPresent(
            QuickCommandDestination.self,
            forKey: .destination
        ) ?? .focusedTerminal

        if let decodedRunner = try container.decodeIfPresent(
            QuickCommandRunner.self,
            forKey: .runner
        ) {
            runner = decodedRunner
        } else {
            switch try container.decodeIfPresent(LegacyAction.self, forKey: .action) {
            case .agentPrompt:
                let agent = try container.decodeIfPresent(LegacyAgent.self, forKey: .agent)
                    ?? .codex
                runner = agent == .claude ? .claude : .codex
            case .terminalCommand, nil:
                runner = .terminal
            }
        }

        if runner.isAgent {
            destination = .newTab
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(runner, forKey: .runner)
        try container.encode(body, forKey: .body)
        try container.encode(destination, forKey: .destination)
        try container.encode(appendEnter, forKey: .appendEnter)
        try container.encode(scope, forKey: .scope)
    }
}

private struct QuickCommandDocument: Codable {
    var commands: [QuickCommand]
    var recentCommandID: UUID?
}

@MainActor
@Observable
final class QuickCommandStore {
    private(set) var commands: [QuickCommand]
    private(set) var recentCommandID: UUID?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "quick-commands.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let document = try? JSONDecoder().decode(QuickCommandDocument.self, from: data) {
            commands = Self.normalized(document.commands)
            recentCommandID = document.recentCommandID
        } else {
            commands = []
            recentCommandID = nil
        }
        if !commands.contains(where: { $0.id == recentCommandID }) {
            recentCommandID = nil
        }
    }

    func upsert(_ command: QuickCommand) {
        let command = command.normalized
        guard command.isComplete else { return }
        if let index = commands.firstIndex(where: { $0.id == command.id }) {
            commands[index] = command
        } else if commands.count < QuickCommand.maximumCount {
            commands.append(command)
        }
        persist()
    }

    func delete(_ commandID: UUID) {
        commands.removeAll { $0.id == commandID }
        if recentCommandID == commandID { recentCommandID = nil }
        persist()
    }

    func recordRun(_ commandID: UUID) {
        guard commands.contains(where: { $0.id == commandID }) else { return }
        recentCommandID = commandID
        persist()
    }

    func visible(projectPath: String?) -> [QuickCommand] {
        commands.filter { $0.scope.includes(projectPath: projectPath) }
    }

    func recent(projectPath: String?) -> QuickCommand? {
        guard let recentCommandID else { return nil }
        return visible(projectPath: projectPath).first { $0.id == recentCommandID }
    }

    func ranked(query: String, projectPath: String?) -> [QuickCommand] {
        let visible = visible(projectPath: projectPath)
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return visible.sorted { lhs, rhs in
                if lhs.id == recentCommandID { return true }
                if rhs.id == recentCommandID { return false }
                if lhs.scope.projectPath != nil, rhs.scope.projectPath == nil { return true }
                if lhs.scope.projectPath == nil, rhs.scope.projectPath != nil { return false }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
        }

        return visible.compactMap { command -> (QuickCommand, Int)? in
            let labelScore = Fuzzy.match(query, in: command.label)?.score
            let bodyScore = Fuzzy.match(query, in: command.body).map { $0.score - 4 }
            let runnerScore = command.runner.isAgent
                ? Fuzzy.match(query, in: command.runner.label).map { $0.score - 6 }
                : nil
            guard let score = [labelScore, bodyScore, runnerScore].compactMap({ $0 }).max()
            else { return nil }
            return (command, score)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.0.id == recentCommandID { return true }
            if rhs.0.id == recentCommandID { return false }
            return lhs.0.label.localizedCaseInsensitiveCompare(rhs.0.label) == .orderedAscending
        }
        .map(\.0)
    }

    private static func normalized(_ commands: [QuickCommand]) -> [QuickCommand] {
        var ids: Set<UUID> = []
        return commands.prefix(QuickCommand.maximumCount).compactMap { command in
            let command = command.normalized
            guard command.isComplete, ids.insert(command.id).inserted else { return nil }
            return command
        }
    }

    private func persist() {
        let document = QuickCommandDocument(
            commands: commands,
            recentCommandID: recentCommandID
        )
        guard let data = try? JSONEncoder().encode(document) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

@MainActor
enum QuickCommandExecutor {
    @discardableResult
    static func run(
        _ command: QuickCommand,
        workspaceStore: WorkspaceStore,
        terminalPool: SurfacePool
    ) -> Bool {
        let command = command.normalized
        guard command.isComplete,
              let workspace = workspaceStore.catalog.activeWorkspace
        else { return false }

        switch command.runner {
        case .terminal:
            let paneID: UUID
            if command.destination == .focusedTerminal,
               let activePaneID = workspaceStore.catalog.activeSlotID,
               workspaceStore.catalog.slot(id: activePaneID)?.content == .terminal {
                paneID = activePaneID
            } else {
                workspaceStore.newTab(content: .terminal)
                guard let created = workspaceStore.catalog.activeSlotID,
                      workspaceStore.catalog.slot(id: created)?.content == .terminal
                else { return false }
                paneID = created
            }
            terminalPool.sendTextWhenReady(
                command.body + (command.appendEnter ? "\n" : ""),
                to: paneID
            )

        case .codex, .claude:
            workspaceStore.newTab(content: .terminal)
            guard let paneID = workspaceStore.catalog.activeSlotID,
                  workspaceStore.catalog.slot(id: paneID)?.content == .terminal,
                  let executable = command.runner.executable
            else { return false }
            terminalPool.seedSpawnDirectory(workspace.path, for: paneID)
            terminalPool.sendTextWhenReady(
                executable + " "
                    + AutomationAuthoring.posixQuoted(command.body) + "\n",
                to: paneID
            )
        }
        return true
    }
}
