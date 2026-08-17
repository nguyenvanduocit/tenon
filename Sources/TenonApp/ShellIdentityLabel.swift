// @domain: workspace-model
import Foundation

/// What the title bar's identity zone says beside the app mark.
///
/// The zone is one label's worth of room — ~90 pt once the traffic-light inset, the mark, and
/// the sidebar toggle have taken their share — so it carries the app's name or a workspace's,
/// never both. Which one is a question about what the window is already saying elsewhere:
/// with the sidebar expanded the workspace list is on screen with the active row marked, and
/// with it collapsed the 48 pt rail draws marks whose names live only in a tooltip.
struct ShellIdentityLabel: Equatable {
    let text: String
    /// Whether `text` is a workspace's name rather than the app's. The view reads it to decide
    /// how the label behaves under pressure: a name is truncated and kept, while the wordmark
    /// is dropped whole once the zone is too narrow for it.
    let namesWorkspace: Bool

    static let wordmark = ShellIdentityLabel(text: "Tenon", namesWorkspace: false)

    static func resolve(
        sidebarVisible: Bool,
        workspaceName: String?
    ) -> ShellIdentityLabel {
        guard !sidebarVisible else { return wordmark }
        let name = workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return wordmark }
        return ShellIdentityLabel(text: name, namesWorkspace: true)
    }
}
