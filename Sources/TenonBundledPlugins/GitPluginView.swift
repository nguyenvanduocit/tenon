// @domain: plugin-contributions, pane-chrome
import Foundation
import TenonCore
import TenonIntentCore

enum GitPluginView {
    static let viewID = "git"

    static func body(for pane: GitPlugin.Pane) -> PluginViewNode {
        let model = pane.model
        var children: [PluginViewNode] = [
            branchCard(),
            commitCard(message: pane.commitMessage),
        ]

        if !model.merge.isEmpty {
            children.append(
                sectionCard(
                    title: "Conflicts",
                    entries: model.merge,
                    section: "merge",
                    bulkLabel: nil,
                    bulkAction: nil
                )
            )
        }
        if !model.staged.isEmpty {
            children.append(
                sectionCard(
                    title: "Staged",
                    entries: model.staged,
                    section: "staged",
                    bulkLabel: "Unstage all",
                    bulkAction: action("unstageAll")
                )
            )
        }
        if !model.changed.isEmpty {
            children.append(
                sectionCard(
                    title: "Changes",
                    entries: model.changed,
                    section: "changed",
                    bulkLabel: "Discard all",
                    bulkAction: action("discardAll")
                )
            )
        }
        if !model.changed.isEmpty && model.staged.isEmpty {
            children.append(
                .hstack(
                    spacing: 8,
                    children: [
                        .spacer,
                        button("Stage all", action("stageAll"), style: .primary),
                    ]
                )
            )
        }
        if model.isRepo,
           model.merge.isEmpty,
           model.staged.isEmpty,
           model.changed.isEmpty
        {
            children.append(
                .card(
                    children: [
                        .text(
                            "Working tree clean",
                            style: .caption,
                            weight: .regular,
                            color: .muted
                        ),
                    ]
                )
            )
        }
        if !model.recent.isEmpty {
            children.append(recentCard(model.recent))
        }
        if !model.isRepo {
            children = [
                .card(
                    children: [
                        .text(
                            "No git repository. Set \"Repository path\" in Settings.",
                            style: .caption,
                            weight: .regular,
                            color: .muted
                        ),
                    ]
                ),
            ]
        }
        return .vstack(spacing: 10, children: children)
    }

    static func header(for model: GitStatusModel) -> PaneHeader {
        guard model.isRepo else { return .empty }
        var leading: [PaneHeaderItem] = [
            .image(
                id: "branch-icon",
                systemName: "arrow.triangle.branch",
                tint: .muted,
                tooltip: nil
            ),
            .label(
                id: "branch",
                text: model.branch,
                weight: .medium,
                color: .default,
                truncation: .middle,
                tooltip: nil
            ),
        ]
        if !model.merge.isEmpty {
            leading.append(
                .badge(
                    id: "conflicts",
                    text: "\(model.merge.count) conflicted",
                    tint: .red,
                    tooltip: nil
                )
            )
        }
        if !model.staged.isEmpty {
            leading.append(
                .badge(
                    id: "staged",
                    text: "\(model.staged.count) staged",
                    tint: .green,
                    tooltip: nil
                )
            )
        }
        if !model.changed.isEmpty {
            leading.append(
                .badge(
                    id: "changed",
                    text: "\(model.changed.count) changed",
                    tint: .amber,
                    tooltip: nil
                )
            )
        }

        var trailing: [PaneHeaderItem] = []
        if model.ahead != 0 || model.behind != 0 {
            trailing.append(
                .badge(
                    id: "sync",
                    text: syncText(model),
                    tint: .amber,
                    tooltip: syncTooltip(model)
                )
            )
        }
        trailing.append(
            .iconButton(
                id: "refresh",
                systemName: "arrow.clockwise",
                tint: .default,
                isEnabled: true,
                tooltip: "Refresh",
                accessibilityID: nil
            )
        )
        return PaneHeader(leading: leading, trailing: trailing)
    }

    static func statusBarText(for model: GitStatusModel) -> String {
        guard model.isRepo else { return "⎇ no repo" }
        let count = model.staged.count + model.changed.count + model.merge.count
        var sync = ""
        if model.ahead != 0 { sync += " ↑\(model.ahead)" }
        if model.behind != 0 { sync += " ↓\(model.behind)" }
        return "⎇ \(model.branch)\(count == 0 ? "" : " ±\(count)")\(sync)"
    }

    static func shortName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private static func branchCard() -> PluginViewNode {
        .card(
            children: [
                .hstack(
                    spacing: 8,
                    children: [
                        button("Switch branch", action("switchBranch")),
                        .spacer,
                        button("Fetch", action("fetch")),
                        button("Pull", action("pull")),
                        button("Push", action("push")),
                    ]
                ),
                .hstack(
                    spacing: 8,
                    children: [
                        button("Stash", action("stash")),
                        button("Pop stash", action("stashPop")),
                        .spacer,
                    ]
                ),
                .field(
                    label: "New branch",
                    children: [
                        .textfield(
                            value: "",
                            placeholder: "branch name",
                            action: action("newBranch")
                        ),
                    ]
                ),
            ]
        )
    }

    private static func commitCard(message: String) -> PluginViewNode {
        .card(
            children: [
                .field(
                    label: "Commit message",
                    children: [
                        .textfield(
                            value: message,
                            placeholder: "Message…",
                            action: action("commitMsg")
                        ),
                    ]
                ),
                .hstack(
                    spacing: 8,
                    children: [
                        .spacer,
                        button("Commit staged", action("commit"), style: .primary),
                        button("Commit all", action("commitAll")),
                    ]
                ),
            ]
        )
    }

    private static func sectionCard(
        title: String,
        entries: [GitChangeEntry],
        section: String,
        bulkLabel: String?,
        bulkAction: PluginNodeAction?
    ) -> PluginViewNode {
        var header: [PluginViewNode] = [
            .text(title, style: .body, weight: .semibold, color: .text),
            .spacer,
        ]
        if let bulkLabel, let bulkAction {
            header.append(button(bulkLabel, bulkAction))
        }
        var children: [PluginViewNode] = [
            .hstack(spacing: 6, children: header),
        ]
        children.append(contentsOf: entries.map { fileRow($0, section: section) })
        return .card(children: children)
    }

    private static func fileRow(
        _ entry: GitChangeEntry,
        section: String
    ) -> PluginViewNode {
        let meta = statusMeta(section == "staged" ? entry.staged : entry.unstaged)
        var children: [PluginViewNode] = [
            .badge(meta.code, tint: meta.tint),
            button(
                entry.path,
                action("open", fields: [
                    "section": .string(section),
                    "path": .string(entry.path),
                ])
            ),
            .spacer,
        ]
        if section == "staged" {
            children.append(
                button(
                    "Unstage",
                    action("unstage", fields: ["path": .string(entry.path)])
                )
            )
        } else if section == "changed" {
            children.append(
                button(
                    "Stage",
                    action("stage", fields: ["path": .string(entry.path)])
                )
            )
            children.append(
                button(
                    "Discard",
                    action("discard", fields: ["path": .string(entry.path)])
                )
            )
        }
        return .hstack(spacing: 6, children: children)
    }

    private static func recentCard(_ commits: [GitRecentCommit]) -> PluginViewNode {
        var children: [PluginViewNode] = [
            .text("Recent", style: .caption, weight: .semibold, color: .muted),
        ]
        for commit in commits {
            children.append(
                .hstack(
                    spacing: 6,
                    children: [
                        .text(commit.hash, style: .code, weight: .regular, color: .amber),
                        .text(commit.subject, style: .caption, weight: .regular, color: .muted),
                    ]
                )
            )
        }
        return .card(children: children)
    }

    private static func button(
        _ label: String,
        _ action: PluginNodeAction,
        style: ButtonStyle = .plain
    ) -> PluginViewNode {
        .button(label: label, action: action, style: style)
    }

    private static func action(
        _ name: String,
        fields: [String: IntentValue] = [:]
    ) -> PluginNodeAction {
        var object = fields
        object["do"] = .string(name)
        return .structured(.object(object))
    }

    private static func statusMeta(_ character: String) -> (code: String, tint: ColorToken) {
        switch character {
        case "M": ("M", .amber)
        case "A": ("A", .green)
        case "D": ("D", .red)
        case "R": ("R", .amber)
        case "C": ("C", .amber)
        case "U": ("U", .red)
        case "?": ("?", .muted)
        default:
            (character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "•"
                : character.trimmingCharacters(in: .whitespacesAndNewlines), .muted)
        }
    }

    private static func syncText(_ model: GitStatusModel) -> String {
        var parts: [String] = []
        if model.ahead != 0 { parts.append("↑\(model.ahead)") }
        if model.behind != 0 { parts.append("↓\(model.behind)") }
        return parts.joined(separator: " ")
    }

    private static func syncTooltip(_ model: GitStatusModel) -> String {
        var parts: [String] = []
        if model.ahead != 0 { parts.append("\(model.ahead) ahead") }
        if model.behind != 0 { parts.append("\(model.behind) behind") }
        return "\(parts.joined(separator: ", ")) \(model.upstream ?? "upstream")"
    }
}
