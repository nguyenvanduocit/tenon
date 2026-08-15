// @domain: plugin-contributions
import TenonCore

enum KanbanBoardView {
    private static let columnWidth = 260.0

    struct Run: Sendable, Equatable {
        let paneID: String
        let agent: String?
        let exited: Bool
        let tail: String
        let error: String
    }

    static func body(
        columns: [KanbanBoardFormat.Column],
        writeError: String,
        error: String
    ) -> PluginViewNode {
        var children: [PluginViewNode] = []
        if !writeError.isEmpty {
            children.append(
                .text(
                    KanbanBoardFormat.clip(writeError, to: KanbanBoardFormat.maximumLabelLength),
                    style: .body,
                    weight: .regular,
                    color: .red
                )
            )
        }
        if !error.isEmpty {
            children.append(
                .text(
                    KanbanBoardFormat.clip(error, to: KanbanBoardFormat.maximumLabelLength),
                    style: .body,
                    weight: .regular,
                    color: .red
                )
            )
        }
        if !columns.isEmpty {
            children.append(
                .scroll(axis: .horizontal, children: [
                    .hstack(
                        spacing: 12,
                        children: columns.enumerated().map { index, column in
                            columnNode(column, index: index, columnCount: columns.count)
                        }
                    ),
                ])
            )
        }
        return .vstack(spacing: 10, children: children)
    }

    static func header(boardPath: String) -> PaneHeader {
        PaneHeader(
            leading: [
                .label(
                    id: "board",
                    text: boardPath,
                    weight: .regular,
                    color: .muted,
                    truncation: .head,
                    tooltip: nil
                ),
            ]
        )
    }

    static func modal(
        task: KanbanBoardFormat.Task?,
        detail: KanbanBoardFormat.Detail?,
        run: Run?,
        agents: [(id: String, label: String)]
    ) -> PluginViewModal? {
        guard let task else { return nil }
        var children: [PluginViewNode] = []

        if let description = detail?.description, !description.isEmpty {
            children.append(.text(description, style: .body, weight: .regular, color: .muted))
        }
        if let detail, !detail.priority.isEmpty || !detail.effort.isEmpty {
            children.append(
                .text(
                    "priority \(detail.priority.isEmpty ? "—" : detail.priority)  ·  effort \(detail.effort.isEmpty ? "—" : detail.effort)",
                    style: .caption,
                    weight: .regular,
                    color: .muted
                )
            )
        }
        if let detail {
            for criterion in detail.criteria {
                children.append(
                    .hstack(spacing: 6, children: [
                        .image(systemName: criterion.done ? "checkmark.circle.fill" : "circle"),
                        .text(criterion.text, style: .body, weight: .regular, color: .default),
                    ])
                )
            }
        }

        appendRun(task: task, run: run, agents: agents, to: &children)

        return PluginViewModal(
            title: "\(task.id) · \(KanbanBoardFormat.clip(task.title, to: KanbanBoardFormat.maximumCardTitleLength))",
            body: .vstack(spacing: 8, children: children),
            dismissAction: "close-detail"
        )
    }

    private static func columnNode(
        _ column: KanbanBoardFormat.Column,
        index: Int,
        columnCount: Int
    ) -> PluginViewNode {
        var children: [PluginViewNode] = [
            .hstack(spacing: 6, children: [
                .text(
                    KanbanBoardFormat.clip(column.name, to: KanbanBoardFormat.maximumLabelLength),
                    style: .body,
                    weight: .semibold,
                    color: .default
                ),
                .spacer,
                .badge(String(column.tasks.count), tint: .muted),
            ]),
        ]

        let shown = column.tasks.prefix(KanbanBoardFormat.maximumRowsPerColumn)
        children.append(
            contentsOf: shown.map { task in
                cardNode(task, columnIndex: index, columnCount: columnCount)
            }
        )
        if column.tasks.count > shown.count {
            children.append(
                .text(
                    "… \(column.tasks.count - shown.count) more",
                    style: .caption,
                    weight: .regular,
                    color: .muted
                )
            )
        }
        children.append(.spacer)

        return .dropTarget(
            action: .string("drop-into:\(index)"),
            children: [
                .box(
                    padding: 10,
                    background: true,
                    cornerRadius: 10,
                    width: columnWidth,
                    children: children
                ),
            ]
        )
    }

    private static func cardNode(
        _ task: KanbanBoardFormat.Task,
        columnIndex: Int,
        columnCount: Int
    ) -> PluginViewNode {
        var top: [PluginViewNode] = [
            .text(task.id, style: .code, weight: .regular, color: .default),
            .spacer,
        ]
        if !task.meta.isEmpty {
            top.append(
                .badge(
                    KanbanBoardFormat.clip(task.meta, to: KanbanBoardFormat.maximumCardMetaLength),
                    tint: .amber
                )
            )
        }

        var controls: [PluginViewNode] = []
        if columnIndex > 0 {
            controls.append(.button(label: "◀", action: .string("move-left:\(task.id)"), style: .plain))
        }
        if columnIndex < columnCount - 1 {
            controls.append(.button(label: "▶", action: .string("move-right:\(task.id)"), style: .plain))
        }
        controls.append(.button(label: "Start", action: .string("start:\(task.id)"), style: .plain))
        controls.append(.button(label: "More", action: .string("more:\(task.id)"), style: .plain))

        return .dragSource(
            payload: task.id,
            children: [
                .card(children: [
                    .hstack(spacing: 6, children: top),
                    .text(
                        KanbanBoardFormat.clip(
                            task.title,
                            to: KanbanBoardFormat.maximumCardTitleLength
                        ),
                        style: .body,
                        weight: .regular,
                        color: .default
                    ),
                    .hstack(spacing: 6, children: controls),
                ]),
            ]
        )
    }

    private static func appendRun(
        task: KanbanBoardFormat.Task,
        run: Run?,
        agents: [(id: String, label: String)],
        to children: inout [PluginViewNode]
    ) {
        children.append(.divider)
        guard let run else {
            children.append(
                .text(
                    agents.isEmpty
                        ? "No coding agent found on this machine."
                        : "No agent started for this task yet.",
                    style: .caption,
                    weight: .regular,
                    color: .muted
                )
            )
            let buttons = agents.map { agent in
                PluginViewNode.button(
                    label: agents.count == 1 ? "Start agent" : "Start \(agent.label)",
                    action: .string("start:\(agent.id):\(task.id)"),
                    style: .plain
                )
            }
            if !buttons.isEmpty {
                children.append(.hstack(spacing: 6, children: buttons))
            }
            return
        }

        children.append(
            .hstack(spacing: 6, children: [
                .badge(run.exited ? "exited" : "running", tint: run.exited ? .muted : .green),
                .text(
                    "pane \(String(run.paneID.prefix(8)))",
                    style: .code,
                    weight: .regular,
                    color: .muted
                ),
            ])
        )
        if !run.error.isEmpty {
            children.append(
                .text("Tracking stopped: \(run.error)", style: .body, weight: .regular, color: .red)
            )
        }
        if !run.tail.isEmpty {
            children.append(.text(run.tail, style: .code, weight: .regular, color: .muted))
        }
        children.append(
            .hstack(spacing: 6, children: [
                .button(label: "Focus pane", action: .string("focus:\(task.id)"), style: .plain),
                .spacer,
                .button(
                    label: "Start again",
                    action: .string(run.agent.map { "start:\($0):\(task.id)" } ?? "start:\(task.id)"),
                    style: .plain
                ),
            ])
        )
    }
}
