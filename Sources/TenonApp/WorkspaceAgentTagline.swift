// @domain: attention, workspace-model
import Foundation
import TenonCore

/// What the line under a workspace's name says, and what its hover popover lists.
///
/// The sidebar row used to print `"3 tabs"`. A tab count is the one fact about a workspace a
/// supervisor never needs: it is stable, it is already visible in the tab strip, and it says
/// nothing about whether anything in there wants them. This projection replaces it with the
/// work — the agent panes the workspace holds, named by whatever each agent last called
/// itself. The row carries the first of them and counts the rest; the popover carries all of
/// them, with a way into each.
///
/// Pure on purpose, and it owns no attention judgement — `state` is copied out of the one
/// `PaneActivity` machine (`docs/domains.md`, `attention`), because a second answer to "is
/// this busy" is how a supervisor learns to distrust the signal.
enum WorkspaceAgentTagline {
    /// One agent pane as the row shows it.
    struct Entry: Equatable, Identifiable {
        let slotID: UUID
        let title: String
        let state: PaneActivityState

        var id: UUID { slotID }
    }

    /// What is drawn to the left of the title. `pulse` is a case rather than a symbol name
    /// because a moving indicator is a live view, not a glyph, and the caller must mount it
    /// as one.
    ///
    /// It is a filled dot that breathes rather than a `ProgressView`, and that was measured:
    /// a mini `ProgressView` scaled to this size renders as a plain ring in a still frame,
    /// which is pixel-identical to `idle`'s hollow circle. An indicator whose whole job is to
    /// say "this one is still moving" may not depend on motion to be distinguishable — the
    /// filled/hollow pair reads at a glance in a screenshot, and the pulse is what it adds
    /// once the row is live.
    enum Indicator: Equatable {
        case pulse
        case symbol(String)
    }

    /// The pane a row falls back to naming when an agent has told us nothing. Short by
    /// necessity: this string competes with the workspace name for a 110 pt row.
    static let unnamed = "Agent"

    /// This workspace's agent panes, in catalog order — tab order, then slot order inside a
    /// tab — so the line names the same pane across renders and the popover lists them in the
    /// order they sit in the tabs, while their states change under both.
    ///
    /// `agentPanes` is the roster's answer and the only agent-ness judgement in the join. The
    /// content check beside it asks a different question: a slot that has since become a file
    /// or a diff is no longer a terminal running anything, whatever the roster still holds.
    static func entries(
        in workspace: Workspace,
        agentPanes: Set<UUID>,
        titles: [UUID: String],
        attention: [UUID: PaneActivity]
    ) -> [Entry] {
        workspace.tabs.flatMap { tab in
            tab.slots.compactMap { slot -> Entry? in
                guard agentPanes.contains(slot.id), slot.content == .terminal else {
                    return nil
                }
                return Entry(
                    slotID: slot.id,
                    title: title(for: slot, titles: titles),
                    // A pane whose machine has not been seeded yet is working: it was just
                    // launched, which is the only way it reached the roster at all.
                    state: attention[slot.id]?.state ?? .working
                )
            }
        }
    }

    /// The title chain the tab chip and the pane header already use
    /// (`BuiltInSlotViews.title(for:...)`): the name a person or an agent pinned, else the
    /// terminal's own title. `tenon-cli rename` writes the first one, and `AgentHarnessText`
    /// instructs every agent running here to set it — so this line usually carries the
    /// sentence the agent wrote about its own work.
    private static func title(for slot: WorkspaceSlot, titles: [UUID: String]) -> String {
        if let custom = slot.customTitle.flatMap(PaneTitle.sanitized) {
            return custom
        }
        return titles[slot.id].flatMap(PaneTitle.sanitized) ?? unnamed
    }

    /// The state vocabulary, drawn. `working` is the one filled shape and the one that moves,
    /// because it is the one state where something is still happening.
    static func indicator(for state: PaneActivityState) -> Indicator {
        switch state {
        case .working:
            return .pulse
        case .idle:
            // A prompt sitting still with nothing to report. Hollow, so it reads as an
            // absence of news rather than as a result.
            return .symbol("circle")
        case .finishedUnseen:
            return .symbol("checkmark.circle.fill")
        case .seen:
            return .symbol("checkmark.circle")
        case .exited:
            return .symbol("xmark.circle")
        }
    }
}
