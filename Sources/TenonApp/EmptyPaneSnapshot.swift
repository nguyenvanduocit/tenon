// @domain: command-surface
import AppKit
import SwiftUI
import TenonCore

/// Dev-only offscreen snapshot of the empty tab/pane launcher card, so what a person meets in
/// an empty pane can be SEEN on a headless machine rather than inferred from a passing test.
///
///     TENON_EMPTY_PANE_SNAPSHOT=/tmp/empty.png swift run tenon
///     TENON_EMPTY_PANE_SNAPSHOT_QUERY='npm run dev' TENON_EMPTY_PANE_SNAPSHOT=/tmp/run.png swift run tenon
///     TENON_EMPTY_PANE_SNAPSHOT_QUERY=ch TENON_EMPTY_PANE_SNAPSHOT=/tmp/filter.png swift run tenon
///
/// Three pictures are worth taking, because the card has three shapes and only the first is
/// the one a test naturally mounts: nothing typed (the grouped layout), a word typed (the
/// ranked list), and a command line typed (the run offer leading it). The card mounted is the
/// same `EmptyStateCard` both real mounts use.
enum EmptyPaneSnapshot {
    @MainActor
    static func renderIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TENON_EMPTY_PANE_SNAPSHOT"], !path.isEmpty else { return }
        render(
            to: path,
            query: env["TENON_EMPTY_PANE_SNAPSHOT_QUERY"] ?? "",
            size: size(env["TENON_EMPTY_PANE_SNAPSHOT_SIZE"])
        )
    }

    @MainActor
    private static func render(to path: String, query: String, size: CGSize) -> Never {
        _ = NSApplication.shared

        let agents: [AgentLaunchSuggestion] = [
            AgentLaunchSuggestion(
                agent: .codex,
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: ["--dangerously-bypass-approvals-and-sandbox"]
            ),
            AgentLaunchSuggestion(
                agent: .claude,
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: ["--dangerously-skip-permissions"]
            ),
            AgentLaunchSuggestion(
                agent: .opencode,
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: ["--auto"]
            ),
        ]
        let recents: [SlotContent] = [
            .terminal,
            .pluginView(pluginID: "dev.tenon.browser", viewID: "browser"),
            .file(path: "/tmp/judge.go"),
            .file(path: "/tmp/prompt.go"),
        ]

        PaneViewSnapshotWriter.write(
            bare: ZStack {
                TenonTheme.ink
                EmptyStateCard(
                    recents: recents,
                    agentSuggestions: agents,
                    isActive: true,
                    initialQuery: query,
                    onLaunch: { _ in },
                    onLaunchAgent: { _ in },
                    onRunCommand: { _ in }
                )
            }
            .frame(width: size.width, height: size.height),
            size: size,
            to: path
        )
    }

    private static func size(_ value: String?) -> CGSize {
        guard let parts = value?.split(separator: "x"), parts.count == 2,
              let width = Double(parts[0]), let height = Double(parts[1]),
              width > 0, height > 0
        else {
            return CGSize(width: 420, height: 620)
        }
        return CGSize(width: width, height: height)
    }
}
