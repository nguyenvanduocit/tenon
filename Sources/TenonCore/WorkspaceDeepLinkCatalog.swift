// @domain: workspace-model
import Foundation
import TenonIntentCore

/// The concrete workspace, tab, and optional pane a deep link resolves to.
///
/// The workspace is derived, never stored: tab ids are globally unique, so the owning
/// workspace is a property of the tree, exactly as `owner(ofSlot:)` treats a pane.
public struct DeepLinkTarget: Equatable, Sendable {
    public let workspaceID: UUID
    public let tabID: UUID
    public let paneID: UUID?

    public init(workspaceID: UUID, tabID: UUID, paneID: UUID?) {
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.paneID = paneID
    }
}

extension WorkspaceCatalog {
    /// Resolves a deep link against the tree it claims to name, or nil when the claimed
    /// hierarchy does not exist. A pane spelling is verified against its named tab — a
    /// deep link is a claim about the tree, so the tree is checked before anything is
    /// selected or focused.
    public func target(for link: WorkspaceDeepLink) -> DeepLinkTarget? {
        switch link {
        case let .tab(tabID):
            guard let workspace = workspaces.first(where: {
                $0.tabs.contains { $0.id == tabID }
            }) else {
                return nil
            }
            return DeepLinkTarget(
                workspaceID: workspace.id,
                tabID: tabID,
                paneID: nil
            )
        case let .pane(tabID, paneID):
            guard let owner = owner(ofSlot: paneID), owner.tabID == tabID else {
                return nil
            }
            return DeepLinkTarget(
                workspaceID: owner.workspaceID,
                tabID: tabID,
                paneID: paneID
            )
        }
    }
}