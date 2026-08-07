import Foundation
import TenonCore
import TenonIntentCore

/// Runs a pane-filling launcher choice against the exact empty grid rectangle the user
/// clicked. The temporary empty pane supplies the scope both `workspace.content.open.v1`
/// and tab-creating content commands need, and is removed without reflow if the command
/// fails or does not honor its `fillsPane` declaration.
@MainActor
enum EmptyGridLauncherPlacement {
    enum Claim: Equatable {
        case notReserved
        case consumed
        case invalidated
    }

    private struct ReservationKey: Hashable {
        let paneID: UUID
        let userGestureID: UUID
    }

    private struct Reservation {
        let workspaceID: UUID
        let tabID: UUID
        let rect: GridRect
        var wasConsumed = false
    }

    private static var reservations: [ReservationKey: Reservation] = [:]

    static func invoke(
        in store: WorkspaceStore,
        targetRect: GridRect,
        userGestureID: UUID = UUID(),
        send: (InvocationScope) async -> IntentResult?
    ) async -> LauncherOutcome {
        let workspaceID = store.catalog.activeWorkspaceID
        guard let tabID = store.catalog.activeTab?.id else { return .targetUnavailable }
        let previousSlotID = store.catalog.activeSlotID
        guard let paneID = store.addSlot(content: .empty, at: targetRect) else {
            return .targetUnavailable
        }

        let key = ReservationKey(paneID: paneID, userGestureID: userGestureID)
        reservations[key] = Reservation(
            workspaceID: workspaceID,
            tabID: tabID,
            rect: targetRect
        )
        defer { reservations[key] = nil }

        let result = await send(InvocationScope(
            workspaceID: workspaceID,
            paneID: paneID,
            userGestureID: userGestureID
        ))
        let placedContent = store.catalog.slot(id: paneID)?.content
        if placedContent != nil, placedContent != .empty {
            return LauncherOutcome(result)
        }

        store.discardEmptySlot(paneID, restoringFocusTo: previousSlotID)
        guard store.catalog.slot(id: paneID) == nil else { return .targetUnavailable }
        guard case .success = result else { return LauncherOutcome(result) }
        return .targetNotFilled
    }

    /// A pane-filling command that implements itself through `workspace.tab.create.v1`
    /// claims the reserved pane instead of opening a tab. Correlation uses both the
    /// pane scope and host-minted gesture identity, matching the title-bar reservation.
    static func consumeReservedTabCreation(
        scope: InvocationScope,
        content: SlotContent?,
        store: WorkspaceStore
    ) -> Claim {
        guard let paneID = scope.paneID,
              let userGestureID = scope.userGestureID
        else { return .notReserved }
        let key = ReservationKey(paneID: paneID, userGestureID: userGestureID)
        guard var reservation = reservations[key] else { return .notReserved }
        guard reservation.wasConsumed == false,
              scope.workspaceID.map({ $0 == reservation.workspaceID }) ?? true,
              let tab = store.catalog.workspaces
                .first(where: { $0.id == reservation.workspaceID })?
                .tabs.first(where: { $0.id == reservation.tabID }),
              let slot = tab.slots.first(where: { $0.id == paneID }),
              slot.content == .empty,
              slot.rect == reservation.rect
        else { return .invalidated }

        let resolvedContent = content ?? store.newTabContentProvider()
        store.setSlotContent(paneID, resolvedContent)
        guard store.catalog.slot(id: paneID)?.content == resolvedContent else {
            return .invalidated
        }
        reservation.wasConsumed = true
        reservations[key] = reservation
        return .consumed
    }

    /// Claims `workspace.content.open.v1` without selecting the reservation's tab or
    /// workspace. A provider may answer after the person has navigated elsewhere; pane
    /// identity is sufficient to place the content and must not steal that newer focus.
    static func consumeReservedContentOpen(
        scope: InvocationScope,
        content: SlotContent,
        store: WorkspaceStore
    ) -> Claim {
        guard let paneID = scope.paneID,
              let userGestureID = scope.userGestureID
        else { return .notReserved }
        let key = ReservationKey(paneID: paneID, userGestureID: userGestureID)
        guard var reservation = reservations[key] else { return .notReserved }
        guard reservation.wasConsumed == false,
              scope.workspaceID.map({ $0 == reservation.workspaceID }) ?? true,
              let tab = store.catalog.workspaces
                .first(where: { $0.id == reservation.workspaceID })?
                .tabs.first(where: { $0.id == reservation.tabID }),
              let slot = tab.slots.first(where: { $0.id == paneID }),
              slot.content == .empty,
              slot.rect == reservation.rect
        else { return .invalidated }

        store.setSlotContent(paneID, content)
        guard store.catalog.slot(id: paneID)?.content == content else {
            return .invalidated
        }
        reservation.wasConsumed = true
        reservations[key] = reservation
        return .consumed
    }
}

/// Runs a title-bar `+` choice against a fresh tab while keeping the chosen intent as
/// the only public operation.
///
/// The blank tab supplies an ordinary workspace/pane scope, so plugin-owned openers keep
/// using their canonical intents and `workspace.content.open.v1` keeps owning content
/// placement inside that tab. Some launcher commands already create a tab themselves;
/// their `workspace.tab.create.v1` call claims this reserved tab instead of opening a
/// second one.
@MainActor
enum NewTabLauncherPlacement {
    private struct ReservationKey: Hashable {
        let paneID: UUID
        let userGestureID: UUID
    }

    private struct Reservation {
        let workspaceID: UUID
        let tab: TenonCore.Tab
        var wasConsumed = false
    }

    private static var reservations: [ReservationKey: Reservation] = [:]

    static func invoke(
        in store: WorkspaceStore,
        userGestureID: UUID = UUID(),
        send: (InvocationScope) async -> IntentResult?
    ) async -> IntentResult? {
        let workspaceID = store.catalog.activeWorkspaceID
        guard let originalTabID = store.catalog.activeTab?.id,
              let originalTabs = store.catalog.activeWorkspace?.tabs
        else { return nil }

        let originalTabIDs = Set(originalTabs.map(\.id))
        store.newTab(content: .empty)
        guard let scopedTab = store.catalog.activeTab,
              !originalTabIDs.contains(scopedTab.id),
              let paneID = scopedTab.activeSlotID ?? scopedTab.slots.first?.id
        else { return nil }

        let reservationKey = ReservationKey(
            paneID: paneID,
            userGestureID: userGestureID
        )
        reservations[reservationKey] = Reservation(
            workspaceID: workspaceID,
            tab: scopedTab
        )
        defer { reservations[reservationKey] = nil }
        let result = await send(InvocationScope(
            workspaceID: workspaceID,
            paneID: paneID,
            userGestureID: userGestureID
        ))

        let scopedTabIsUntouched = reservations[reservationKey]?.wasConsumed == false
            && tab(
                scopedTab.id,
                workspaceID: workspaceID,
                store: store
            ) == scopedTab
        guard case .success = result else {
            let scopedTabWasSelected = store.catalog.activeWorkspaceID == workspaceID
                && store.catalog.activeTab?.id == scopedTab.id
            if scopedTabIsUntouched,
               closeScopedTab(
                   scopedTab.id,
                   workspaceID: workspaceID,
                   store: store
               ),
               scopedTabWasSelected
            {
                store.selectTab(originalTabID)
            }
            return result
        }
        return result
    }

    /// `workspace.tab.create.v1` consumes the title-bar reservation instead of opening a
    /// second tab. Because the claim is keyed by the invocation's pane and host-minted
    /// gesture, an unrelated tab created while the intent awaits can never be mistaken for
    /// the intent's result.
    static func consumeReservedTabCreation(
        scope: InvocationScope,
        content: SlotContent?,
        store: WorkspaceStore
    ) -> Bool {
        guard let paneID = scope.paneID,
              let userGestureID = scope.userGestureID
        else { return false }
        let reservationKey = ReservationKey(
            paneID: paneID,
            userGestureID: userGestureID
        )
        guard var reservation = reservations[reservationKey],
              reservation.wasConsumed == false,
              scope.workspaceID.map({ $0 == reservation.workspaceID }) ?? true,
              tab(
                  reservation.tab.id,
                  workspaceID: reservation.workspaceID,
                  store: store
              ) == reservation.tab
        else { return false }

        let resolvedContent = content ?? store.newTabContentProvider()
        store.setSlotContent(paneID, resolvedContent)
        guard store.catalog.slot(id: paneID)?.content == resolvedContent else { return false }
        reservation.wasConsumed = true
        reservations[reservationKey] = reservation
        return true
    }

    private static func tab(
        _ tabID: UUID,
        workspaceID: UUID,
        store: WorkspaceStore
    ) -> TenonCore.Tab? {
        store.catalog.workspaces
            .first(where: { $0.id == workspaceID })?
            .tabs.first(where: { $0.id == tabID })
    }

    /// Closing by workspace identity preserves whatever workspace/tab the human selected
    /// while the intent was awaiting its reply.
    @discardableResult
    private static func closeScopedTab(
        _ tabID: UUID,
        workspaceID: UUID,
        store: WorkspaceStore
    ) -> Bool {
        guard tab(tabID, workspaceID: workspaceID, store: store) != nil
        else { return false }
        store.closeTab(tabID, in: workspaceID)
        return tab(tabID, workspaceID: workspaceID, store: store) == nil
    }
}

/// What one launcher choice leaves behind, decided from the dispatch result alone.
///
/// Every surface that presents the launcher catalog — the tab strip's `+` popover and a
/// tab chip's right-click popover — settles a chosen row through this value, so no
/// surface can record a habit for a command that never ran, and no surface can swallow
/// a failure the human should have seen.
enum LauncherOutcome: Equatable {
    /// The intent ran: the pick becomes frecency and the launcher closes.
    case ran
    /// The intent vanished between ranking and the click (its plugin unloaded).
    case unavailable
    /// A detected local agent disappeared or stopped being executable before the click.
    case agentUnavailable
    /// The provider answered with an error, reported in place; the launcher stays open.
    case failed(code: String)
    /// The clicked grid region changed before the launcher could reserve it.
    case targetUnavailable
    /// A command declared itself pane-filling but completed without occupying the target.
    case targetNotFilled

    init(_ result: IntentResult?) {
        switch result {
        case nil:
            self = .unavailable
        case .success:
            self = .ran
        case .failure(let failure):
            self = .failed(code: failure.error.code.rawValue)
        }
    }

    /// Only a run that succeeded may teach the ranking.
    var recordsFrecency: Bool { self == .ran }

    /// The launcher closes only behind a success; anything else stays visible where the
    /// click happened.
    var dismisses: Bool { self == .ran }

    var errorMessage: String? {
        switch self {
        case .ran: nil
        case .unavailable: "Intent is no longer available."
        case .agentUnavailable: "This agent is no longer available."
        case .failed(let code): code
        case .targetUnavailable: "This space is no longer available."
        case .targetNotFilled: "This item could not fill this space."
        }
    }
}
