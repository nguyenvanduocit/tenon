// @domain: workspace-model
import Foundation

/// One stable, self-describing address for a tab or pane, spelled as a `tenon://`
/// deep link so an external caller can either open it (focusing the target) or read
/// the hierarchy from the path alone.
///
/// The shape is `tenon://tabs/<tabID>` for a tab and `tenon://tabs/<tabID>/panes/<paneID>`
/// for a pane. The pane spelling carries its owning tab because the tab id is the
/// globally unique half; a pane id alone would not tell a reader which tab it lives
/// in. The same string is what the Copy Pane ID and Copy Tab ID menus put on the
/// clipboard, and what `tenon-cli --tab` / `--pane` accept in place of a bare UUID.
public enum WorkspaceDeepLink: Equatable, Sendable {
    case tab(UUID)
    case pane(tabID: UUID, paneID: UUID)

    /// The tab named by either spelling.
    public var tabID: UUID {
        switch self {
        case let .tab(tabID):
            return tabID
        case let .pane(tabID, _):
            return tabID
        }
    }

    /// The pane named by a pane spelling; nil for a tab spelling.
    public var paneID: UUID? {
        switch self {
        case .tab:
            return nil
        case let .pane(_, paneID):
            return paneID
        }
    }

    /// The canonical deep-link spelling for a tab.
    public static func url(tabID: UUID) -> String {
        "tenon://tabs/\(tabID.uuidString)"
    }

    /// The canonical deep-link spelling for a pane inside its owning tab.
    public static func url(tabID: UUID, paneID: UUID) -> String {
        "tenon://tabs/\(tabID.uuidString)/panes/\(paneID.uuidString)"
    }

    /// Parses one deep link, or nil for anything that is not a well-formed
    /// `tenon://tabs/...` address. Parsing is strict: a trailing slash is tolerated,
    /// but an extra path segment, a bare `tenon://tabs/` with no id, or a non-UUID id
    /// are all refused rather than guessed at.
    public static func parse(_ string: String) -> WorkspaceDeepLink? {
        let components = string.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 3, components[0] == "tenon:" else { return nil }
        guard components[1] == "tabs" else { return nil }

        guard let tabID = UUID(uuidString: String(components[2])) else { return nil }
        if components.count == 3 {
            return .tab(tabID)
        }
        guard components.count == 5, components[3] == "panes" else { return nil }
        guard let paneID = UUID(uuidString: String(components[4])) else { return nil }
        return .pane(tabID: tabID, paneID: paneID)
    }
}