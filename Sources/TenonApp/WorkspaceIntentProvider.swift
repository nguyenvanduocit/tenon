// @domain: intent-bus, workspace-model
import Foundation
import TenonCore
import TenonIntentCore

@MainActor
final class WorkspaceIntentProvider {
    typealias CustomIconNormalizer = @Sendable (
        Data
    ) async throws -> WorkspaceCustomIcon

    private struct ErrorCodes {
        let workspaceUnavailable: IntentErrorCode
        let workspaceNotFound: IntentErrorCode
        let tabNotFound: IntentErrorCode
        let paneNotFound: IntentErrorCode
        let layoutUnavailable: IntentErrorCode
        let closeRefused: IntentErrorCode
        let contentUnavailable: IntentErrorCode
        let cursorInvalidated: IntentErrorCode

        init() throws {
            workspaceUnavailable = .domain(
                try IntentDomainErrorCode(
                    "dev.tenon.core.workspace-unavailable"
                )
            )
            workspaceNotFound = .domain(
                try IntentDomainErrorCode(
                    "dev.tenon.core.workspace-not-found"
                )
            )
            tabNotFound = .domain(
                try IntentDomainErrorCode("dev.tenon.core.tab-not-found")
            )
            paneNotFound = .domain(
                try IntentDomainErrorCode("dev.tenon.core.pane-not-found")
            )
            layoutUnavailable = .domain(
                try IntentDomainErrorCode(
                    "dev.tenon.core.layout-unavailable"
                )
            )
            closeRefused = .domain(
                try IntentDomainErrorCode("dev.tenon.core.close-refused")
            )
            contentUnavailable = .domain(
                try IntentDomainErrorCode(
                    "dev.tenon.core.content-unavailable"
                )
            )
            cursorInvalidated = .domain(
                try IntentDomainErrorCode(
                    "dev.tenon.core.cursor-invalidated"
                )
            )
        }
    }

    private let store: WorkspaceStore
    private let codes: ErrorCodes
    private let normalizeCustomIcon: CustomIconNormalizer

    init(
        store: WorkspaceStore,
        normalizeCustomIcon: @escaping CustomIconNormalizer = {
            try await WorkspaceCustomIconImport.icon(from: $0)
        }
    ) throws {
        self.store = store
        self.normalizeCustomIcon = normalizeCustomIcon
        codes = try ErrorCodes()
    }

    func bindings() throws -> [IntentProviderBinding] {
        [
            IntentProviderBinding(
                intentID: try CoreIntentName.workspaceState.intentID
            ) { envelope, context in
                try context.checkCancellation()
                return await self.state(envelope: envelope)
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.workspaceIdentitySet.intentID
            ) { envelope, context in
                try context.checkCancellation()
                return try await self.setWorkspaceIdentity(envelope: envelope)
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.workspacePaneOwner.intentID
            ) { envelope, context in
                try context.checkCancellation()
                return await self.paneOwner(envelope: envelope)
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.workspaceTabCreate.intentID
            ) { envelope, context in
                try context.checkCancellation()
                return await self.createTab(envelope: envelope)
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.workspaceTabFocus.intentID
            ) { envelope, context in
                try context.checkCancellation()
                return await self.focusTab(envelope: envelope)
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.workspaceTabClose.intentID
            ) { envelope, context in
                try context.checkCancellation()
                return await self.closeTab(envelope: envelope)
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.workspacePaneSplit.intentID
            ) { envelope, context in
                try context.checkCancellation()
                return await self.splitPane(envelope: envelope)
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.workspacePaneFocus.intentID
            ) { envelope, context in
                try context.checkCancellation()
                return await self.focusPane(envelope: envelope)
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.workspacePaneClose.intentID
            ) { envelope, context in
                try context.checkCancellation()
                return await self.closePane(envelope: envelope)
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.workspacePaneContentSet.intentID
            ) { envelope, context in
                try context.checkCancellation()
                return await self.setPaneContent(envelope: envelope)
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.workspacePaneTitleSet.intentID
            ) { envelope, context in
                try context.checkCancellation()
                return await self.setPaneTitle(envelope: envelope)
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.workspaceContentOpen.intentID
            ) { envelope, context in
                try context.checkCancellation()
                return await self.openContent(envelope: envelope)
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.workspaceTabNext.intentID
            ) { envelope, context in
                try context.checkCancellation()
                return await self.selectTab(
                    offset: 1,
                    envelope: envelope
                )
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.workspaceTabPrevious.intentID
            ) { envelope, context in
                try context.checkCancellation()
                return await self.selectTab(
                    offset: -1,
                    envelope: envelope
                )
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.workspacePaneFocusNext.intentID
            ) { envelope, context in
                try context.checkCancellation()
                return await self.focusNextPane(envelope: envelope)
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.workspaceSelect.intentID
            ) { envelope, context in
                try context.checkCancellation()
                return await self.selectWorkspace(envelope: envelope)
            },
        ]
    }
}

private extension WorkspaceIntentProvider {
    func state(envelope: IntentEnvelope) -> IntentProviderReply {
        do {
            let object = try AppIntentProviderSupport.object(
                envelope.input
            )
            let limit = try AppIntentProviderSupport.optionalInteger(
                "limit",
                in: object
            ) ?? 128
            guard (1 ... 256).contains(limit) else {
                throw AppIntentInputError.missingOrInvalidField(
                    "limit"
                )
            }
            let offset: Int
            if let rawCursor = try AppIntentProviderSupport.optionalString(
                "cursor",
                in: object
            ) {
                guard let cursor = Self.decodeCursor(rawCursor),
                      cursor.snapshotID == store.snapshotID
                else {
                    return failure(
                        codes.cursorInvalidated,
                        reason: "workspace-state-changed"
                    )
                }
                offset = cursor.offset
            } else {
                offset = 0
            }
            return .success(
                try Self.snapshotPage(
                    store: store,
                    offset: offset,
                    limit: limit
                )
            )
        } catch let error as AppIntentInputError {
            return AppIntentProviderSupport.invalidInput(error)
        } catch {
            return failure(
                codes.workspaceUnavailable,
                reason: "workspace-state-page-unavailable"
            )
        }
    }

    /// Public adapter over `WorkspaceStore.setWorkspaceIdentity`. Scope is the only
    /// designation: a missing UUID never falls back to the selected workspace, because that
    /// would let a background agent recolour whichever project the person just clicked.
    func setWorkspaceIdentity(
        envelope: IntentEnvelope
    ) async throws -> IntentProviderReply {
        do {
            let object = try AppIntentProviderSupport.object(envelope.input)
            let allowed = Set(["name", "accent", "icon"])
            guard !object.isEmpty, object.keys.allSatisfy(allowed.contains) else {
                throw AppIntentInputError.missingOrInvalidField("identity")
            }
            guard let workspaceID = envelope.scope.workspaceID,
                  let current = store.catalog.workspaces.first(where: {
                      $0.id == workspaceID
                  })
            else {
                return failure(
                    codes.workspaceNotFound,
                    reason: "workspace-scope-not-found"
                )
            }

            let name: String?
            switch object["name"] {
            case .none:
                name = nil
            case let .some(.string(value)):
                name = value
            default:
                throw AppIntentInputError.missingOrInvalidField("name")
            }

            var appearance = current.appearance
            var changesAppearance = false
            if let rawAccent = object["accent"] {
                guard case let .string(value) = rawAccent else {
                    throw AppIntentInputError.missingOrInvalidField("accent")
                }
                if value == "automatic" {
                    appearance.accent = nil
                } else if let accent = AccentColor(rawValue: value) {
                    appearance.accent = accent
                } else {
                    throw AppIntentInputError.missingOrInvalidField("accent")
                }
                changesAppearance = true
            }

            if let rawIcon = object["icon"] {
                let icon = try AppIntentProviderSupport.object(rawIcon)
                guard icon.keys.allSatisfy({ ["kind", "name", "data"].contains($0) })
                else {
                    throw AppIntentInputError.missingOrInvalidField("icon")
                }
                switch try AppIntentProviderSupport.string("kind", in: icon) {
                case "symbol":
                    guard Set(icon.keys) == Set(["kind", "name"]),
                          let symbol = WorkspaceSymbol(
                              rawValue: try AppIntentProviderSupport.string(
                                  "name",
                                  in: icon
                              )
                          )
                    else {
                        throw AppIntentInputError.missingOrInvalidField("icon.name")
                    }
                    appearance.symbol = symbol
                    appearance.customIcon = nil
                case "custom":
                    guard Set(icon.keys) == Set(["kind", "data"]) else {
                        throw AppIntentInputError.missingOrInvalidField("icon.data")
                    }
                    let encoded = try AppIntentProviderSupport.string("data", in: icon)
                    guard encoded.count
                        <= WorkspaceCustomIcon.maximumImportBase64Characters,
                        let data = Data(base64Encoded: encoded)
                    else {
                        throw AppIntentInputError.missingOrInvalidField("icon.data")
                    }
                    do {
                        appearance.customIcon = try await normalizeCustomIcon(data)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        throw AppIntentInputError.missingOrInvalidField("icon.data")
                    }
                default:
                    throw AppIntentInputError.missingOrInvalidField("icon.kind")
                }
                changesAppearance = true
            }

            store.setWorkspaceIdentity(
                workspaceID,
                name: name,
                appearance: changesAppearance ? appearance : nil
            )
            guard let updated = store.catalog.workspaces.first(where: {
                $0.id == workspaceID
            }) else {
                return failure(
                    codes.workspaceNotFound,
                    reason: "workspace-identity-update-failed"
                )
            }
            return .success(Self.identityValue(updated))
        } catch let error as AppIntentInputError {
            return AppIntentProviderSupport.invalidInput(error)
        }
    }

    /// One pane in, one owner out. A pane the catalog does not hold and a pane whose id is
    /// not a UUID are different failures on purpose: the first is a state answer
    /// (`workspace-unavailable`), the second is a malformed request.
    func paneOwner(envelope: IntentEnvelope) -> IntentProviderReply {
        do {
            let object = try AppIntentProviderSupport.object(envelope.input)
            let raw = try AppIntentProviderSupport.string("paneID", in: object)
            guard let paneID = UUID(uuidString: raw) else {
                throw AppIntentInputError.missingOrInvalidField("paneID")
            }
            guard let value = Self.paneOwnerValue(
                catalog: store.catalog,
                paneID: paneID
            ) else {
                return failure(
                    codes.workspaceUnavailable,
                    reason: "pane-unknown"
                )
            }
            return .success(value)
        } catch let error as AppIntentInputError {
            return AppIntentProviderSupport.invalidInput(error)
        } catch {
            return failure(
                codes.workspaceUnavailable,
                reason: "pane-unknown"
            )
        }
    }

    func createTab(envelope: IntentEnvelope) -> IntentProviderReply {
        do {
            let object = try AppIntentProviderSupport.object(envelope.input)
            let content = try object["content"].map { try Self.content(from: $0) }
            switch EmptyGridLauncherPlacement.consumeReservedTabCreation(
                scope: envelope.scope,
                content: content,
                store: store
            ) {
            case .consumed:
                return AppIntentProviderSupport.emptySuccess
            case .invalidated:
                return failure(
                    codes.layoutUnavailable,
                    reason: "empty-grid-reservation-invalidated"
                )
            case .notReserved:
                break
            }
            if NewTabLauncherPlacement.consumeReservedTabCreation(
                scope: envelope.scope,
                content: content,
                store: store
            ) {
                return AppIntentProviderSupport.emptySuccess
            }

            guard selectScopedWorkspace(envelope.scope) else {
                return failure(
                    envelope.scope.tabID == nil
                        ? codes.workspaceNotFound
                        : codes.tabNotFound,
                    reason: envelope.scope.tabID == nil
                        ? "workspace-scope-not-found"
                        : "tab-scope-not-found"
                )
            }

            let previousTabIDs = Set(
                store.catalog.activeWorkspace?.tabs.map(\.id) ?? []
            )
            store.newTab(content: content)
            let currentTabIDs = Set(
                store.catalog.activeWorkspace?.tabs.map(\.id) ?? []
            )
            guard currentTabIDs.count == previousTabIDs.count + 1 else {
                return failure(
                    codes.workspaceUnavailable,
                    reason: "tab-create-refused"
                )
            }
            return AppIntentProviderSupport.emptySuccess
        } catch let error as AppIntentInputError {
            return AppIntentProviderSupport.invalidInput(error)
        } catch {
            return failure(
                codes.contentUnavailable,
                reason: "content-is-invalid"
            )
        }
    }

    func focusTab(envelope: IntentEnvelope) -> IntentProviderReply {
        guard envelope.input == .object([:]) else {
            return AppIntentProviderSupport.invalidInput(.expectedObject)
        }
        guard envelope.scope.tabID != nil,
              selectScopedTab(envelope.scope)
        else {
            return failure(codes.tabNotFound, reason: "tab-scope-not-found")
        }
        return AppIntentProviderSupport.emptySuccess
    }

    /// `workspace.tab.close.v1` — the public adapter over the same `WorkspaceStore.closeTab`
    /// the tab bar's close button calls DIRECT.
    ///
    /// Two refusals, told apart because a caller acts differently on each. No tab in scope
    /// is `tab-not-found`: the intent will not guess at the selection for a destructive
    /// operation. A workspace's only tab is `close-refused`, because `WorkspaceCatalog`
    /// keeps it (`Workspace.swift:613`) and a caller looping over tabs meets that case
    /// first — reporting success there would claim a removal that never happened.
    func closeTab(envelope: IntentEnvelope) -> IntentProviderReply {
        guard envelope.input == .object([:]) else {
            return AppIntentProviderSupport.invalidInput(.expectedObject)
        }
        guard let tabID = envelope.scope.tabID,
              let owner = store.catalog.workspaces.first(where: { workspace in
                  workspace.tabs.contains { $0.id == tabID }
              }),
              envelope.scope.workspaceID.map({ $0 == owner.id }) ?? true
        else {
            return failure(codes.tabNotFound, reason: "tab-scope-not-found")
        }
        guard owner.tabs.count > 1 else {
            return failure(codes.closeRefused, reason: "last-tab-cannot-close")
        }

        store.closeTab(tabID, in: owner.id)
        guard !(store.catalog.workspaces.first { $0.id == owner.id }?
            .tabs.contains { $0.id == tabID } ?? false)
        else {
            return failure(codes.closeRefused, reason: "tab-close-refused")
        }
        return AppIntentProviderSupport.emptySuccess
    }

    func splitPane(envelope: IntentEnvelope) -> IntentProviderReply {
        do {
            let object = try AppIntentProviderSupport.object(envelope.input)
            let axisValue = try AppIntentProviderSupport.string(
                "axis",
                in: object
            )
            let axis: SplitAxis
            switch axisValue {
            case "horizontal":
                axis = .horizontal
            case "vertical":
                axis = .vertical
            default:
                throw AppIntentInputError.missingOrInvalidField("axis")
            }
            guard let paneID = envelope.scope.paneID,
                  store.catalog.slot(id: paneID) != nil
            else {
                return failure(codes.paneNotFound, reason: "pane-scope-not-found")
            }

            store.focusSlot(paneID)
            let before = Set(store.catalog.allSlotIDs)
            store.splitSlot(paneID, axis)
            let after = Set(store.catalog.allSlotIDs)
            guard after.count == before.count + 1 else {
                return failure(
                    codes.layoutUnavailable,
                    reason: "pane-cannot-be-split"
                )
            }
            return AppIntentProviderSupport.emptySuccess
        } catch let error as AppIntentInputError {
            return AppIntentProviderSupport.invalidInput(error)
        } catch {
            return AppIntentProviderSupport.invalidInput(
                .missingOrInvalidField("$")
            )
        }
    }

    func focusPane(envelope: IntentEnvelope) -> IntentProviderReply {
        guard envelope.input == .object([:]) else {
            return AppIntentProviderSupport.invalidInput(.expectedObject)
        }
        guard let paneID = envelope.scope.paneID,
              store.catalog.slot(id: paneID) != nil
        else {
            return failure(codes.paneNotFound, reason: "pane-scope-not-found")
        }

        store.focusSlot(paneID)
        guard store.catalog.activeSlotID == paneID else {
            return failure(codes.paneNotFound, reason: "pane-focus-failed")
        }
        return AppIntentProviderSupport.emptySuccess
    }

    func closePane(envelope: IntentEnvelope) -> IntentProviderReply {
        guard envelope.input == .object([:]) else {
            return AppIntentProviderSupport.invalidInput(.expectedObject)
        }
        guard let paneID = envelope.scope.paneID,
              store.catalog.slot(id: paneID) != nil
        else {
            return failure(codes.paneNotFound, reason: "pane-scope-not-found")
        }

        store.focusSlot(paneID)
        store.closeSlot(paneID)
        guard store.catalog.slot(id: paneID) == nil else {
            return failure(codes.closeRefused, reason: "pane-close-refused")
        }
        return AppIntentProviderSupport.emptySuccess
    }

    func setPaneContent(envelope: IntentEnvelope) -> IntentProviderReply {
        do {
            let object = try AppIntentProviderSupport.object(envelope.input)
            guard let value = object["content"] else {
                throw AppIntentInputError.missingOrInvalidField("content")
            }
            let content = try Self.content(from: value)
            guard let paneID = envelope.scope.paneID,
                  store.catalog.slot(id: paneID) != nil
            else {
                return failure(codes.paneNotFound, reason: "pane-scope-not-found")
            }

            store.setSlotContent(paneID, content)
            guard store.catalog.slot(id: paneID)?.content == content else {
                return failure(
                    codes.contentUnavailable,
                    reason: "pane-content-update-failed"
                )
            }
            return AppIntentProviderSupport.emptySuccess
        } catch let error as AppIntentInputError {
            return AppIntentProviderSupport.invalidInput(error)
        } catch {
            return failure(
                codes.contentUnavailable,
                reason: "content-is-invalid"
            )
        }
    }

    /// The public adapter over the same `renameSlot` the rename UI and the Companion title
    /// generator call DIRECT (invariant 6). Scope names the pane, exactly as it does for
    /// focus, close, and content: a caller that omits it is refused rather than renaming
    /// whichever pane happens to be focused, which is how one agent would relabel another's.
    ///
    /// An empty or whitespace-only title clears the pin — the same operation, not a second
    /// contract — because `PaneTitle.sanitized` answers nil for both.
    func setPaneTitle(envelope: IntentEnvelope) -> IntentProviderReply {
        do {
            let object = try AppIntentProviderSupport.object(envelope.input)
            let title = try AppIntentProviderSupport.string("title", in: object)
            guard let paneID = envelope.scope.paneID,
                  store.catalog.slot(id: paneID) != nil
            else {
                return failure(codes.paneNotFound, reason: "pane-scope-not-found")
            }

            store.renameSlot(paneID, to: title)
            guard store.catalog.slot(id: paneID)?.customTitle
                == PaneTitle.sanitized(title)
            else {
                return failure(codes.paneNotFound, reason: "pane-title-update-failed")
            }
            return AppIntentProviderSupport.emptySuccess
        } catch let error as AppIntentInputError {
            return AppIntentProviderSupport.invalidInput(error)
        } catch {
            return failure(codes.paneNotFound, reason: "pane-title-update-failed")
        }
    }

    /// Places content without the caller choosing a pane: the pane already showing this
    /// kind of content takes it, and otherwise one is split beside. The scope pane or tab
    /// names the tab; without either, content opens into the scoped workspace's active tab.
    func openContent(envelope: IntentEnvelope) -> IntentProviderReply {
        do {
            let object = try AppIntentProviderSupport.object(envelope.input)
            guard let value = object["content"] else {
                throw AppIntentInputError.missingOrInvalidField("content")
            }
            let content = try Self.content(from: value)

            switch EmptyGridLauncherPlacement.consumeReservedContentOpen(
                scope: envelope.scope,
                content: content,
                store: store
            ) {
            case .consumed:
                return AppIntentProviderSupport.emptySuccess
            case .invalidated:
                return failure(
                    codes.layoutUnavailable,
                    reason: "empty-grid-reservation-invalidated"
                )
            case .notReserved:
                break
            }

            if let paneID = envelope.scope.paneID {
                guard store.catalog.slot(id: paneID) != nil else {
                    return failure(
                        codes.paneNotFound,
                        reason: "pane-scope-not-found"
                    )
                }
                store.focusSlot(paneID)
            } else if envelope.scope.tabID != nil {
                guard selectScopedTab(envelope.scope) else {
                    return failure(
                        codes.tabNotFound,
                        reason: "tab-scope-not-found"
                    )
                }
            } else if !selectScopedWorkspace(envelope.scope) {
                return failure(
                    codes.workspaceNotFound,
                    reason: "workspace-scope-not-found"
                )
            }

            let tabsBefore = store.catalog.activeWorkspace?.tabs.count
            store.openContent(content)
            guard store.catalog.activeTab?.slots.contains(where: {
                $0.content == content
            }) == true else {
                return failure(
                    codes.layoutUnavailable,
                    reason: "content-cannot-be-placed"
                )
            }
            guard store.catalog.activeWorkspace?.tabs.count == tabsBefore else {
                return failure(
                    codes.workspaceUnavailable,
                    reason: "placement-opened-a-tab"
                )
            }
            return AppIntentProviderSupport.emptySuccess
        } catch let error as AppIntentInputError {
            return AppIntentProviderSupport.invalidInput(error)
        } catch {
            return failure(
                codes.contentUnavailable,
                reason: "content-is-invalid"
            )
        }
    }

    func selectTab(
        offset: Int,
        envelope: IntentEnvelope
    ) -> IntentProviderReply {
        guard envelope.input == .object([:]) else {
            return AppIntentProviderSupport.invalidInput(.expectedObject)
        }
        guard envelope.scope.tabID == nil
            ? selectScopedWorkspace(envelope.scope)
            : selectScopedTab(envelope.scope)
        else {
            return failure(
                envelope.scope.tabID == nil
                    ? codes.workspaceNotFound
                    : codes.tabNotFound,
                reason: envelope.scope.tabID == nil
                    ? "workspace-scope-not-found"
                    : "tab-scope-not-found"
            )
        }
        if offset > 0 {
            store.selectNextTab()
        } else {
            store.selectPreviousTab()
        }
        return AppIntentProviderSupport.emptySuccess
    }

    func focusNextPane(envelope: IntentEnvelope) -> IntentProviderReply {
        guard envelope.input == .object([:]) else {
            return AppIntentProviderSupport.invalidInput(.expectedObject)
        }
        if let paneID = envelope.scope.paneID {
            guard store.catalog.slot(id: paneID) != nil else {
                return failure(
                    codes.paneNotFound,
                    reason: "pane-scope-not-found"
                )
            }
            store.focusSlot(paneID)
        } else if envelope.scope.tabID != nil {
            guard selectScopedTab(envelope.scope) else {
                return failure(codes.tabNotFound, reason: "tab-scope-not-found")
            }
        } else if !selectScopedWorkspace(envelope.scope) {
            return failure(
                codes.workspaceNotFound,
                reason: "workspace-scope-not-found"
            )
        }
        store.focusNextSlot()
        return AppIntentProviderSupport.emptySuccess
    }

    func selectWorkspace(envelope: IntentEnvelope) -> IntentProviderReply {
        guard envelope.input == .object([:]) else {
            return AppIntentProviderSupport.invalidInput(.expectedObject)
        }
        guard let workspaceID = envelope.scope.workspaceID,
              store.catalog.workspaces.contains(where: { $0.id == workspaceID })
        else {
            return failure(
                codes.workspaceNotFound,
                reason: "workspace-scope-not-found"
            )
        }
        store.selectWorkspace(workspaceID)
        guard store.catalog.activeWorkspaceID == workspaceID else {
            return failure(
                codes.workspaceUnavailable,
                reason: "workspace-selection-failed"
            )
        }
        return AppIntentProviderSupport.emptySuccess
    }

    func selectScopedWorkspace(_ scope: InvocationScope) -> Bool {
        if let tabID = scope.tabID {
            guard let workspace = store.catalog.workspaces.first(where: {
                $0.tabs.contains(where: { $0.id == tabID })
            }), scope.workspaceID.map({ $0 == workspace.id }) ?? true
            else { return false }
            store.selectWorkspace(workspace.id)
            return store.catalog.activeWorkspaceID == workspace.id
        }
        guard let workspaceID = scope.workspaceID else {
            return store.catalog.activeWorkspace != nil
        }
        guard store.catalog.workspaces.contains(where: { $0.id == workspaceID }) else {
            return false
        }
        store.selectWorkspace(workspaceID)
        return store.catalog.activeWorkspaceID == workspaceID
    }

    func selectScopedTab(_ scope: InvocationScope) -> Bool {
        guard let tabID = scope.tabID,
              selectScopedWorkspace(scope)
        else { return false }
        store.selectTab(tabID)
        return store.catalog.activeTab?.id == tabID
    }

    func failure(
        _ code: IntentErrorCode,
        reason: String
    ) -> IntentProviderReply {
        AppIntentProviderSupport.failure(code: code, reason: reason)
    }

}

/// The typed parse of the `content` a caller names, kept reachable inside the module.
///
/// It is the door a plugin knocks on — the one place an untrusted caller's idea of "a pane
/// holding this" becomes a `SlotContent` — so it is swept directly, against real files and
/// real symlinks, rather than only through whichever intent happens to call it.
extension WorkspaceIntentProvider {
    /// `transcriptRoots` is a parameter rather than a constant so the containment rule can be
    /// swept against real symlinks in a temporary directory. Production always takes the
    /// default, which is this user's own two provider roots.
    nonisolated static func content(
        from value: IntentValue,
        transcriptRoots: [URL] = AgentTranscriptPath.allowedRoots()
    ) throws -> SlotContent {
        let object = try AppIntentProviderSupport.object(value)
        let kind = try AppIntentProviderSupport.string("kind", in: object)
        switch kind {
        case "agentSession":
            let rawProvider = try AppIntentProviderSupport.string("provider", in: object)
            guard let provider = AgentSessionProvider(rawValue: rawProvider) else {
                throw AppIntentInputError.missingOrInvalidField("provider")
            }
            let rawPath = try AppIntentProviderSupport.string("transcriptPath", in: object)
            // The caller is a plugin naming a file on this person's disk, so containment is
            // decided here, with symlinks resolved on both sides, and decided BEFORE a
            // reference exists. A path that does not resolve under one of the provider roots
            // is a typed invalid-input refusal: no pane opens, and nothing partial is built.
            guard let transcript = AgentTranscriptPath.validated(rawPath, roots: transcriptRoots)
            else {
                throw AppIntentInputError.missingOrInvalidField("transcriptPath")
            }
            let title: String?
            switch object["title"] {
            case .none, .some(.null):
                title = nil
            case let .some(.string(value)):
                title = value
            default:
                throw AppIntentInputError.missingOrInvalidField("title")
            }
            guard let ref = AgentSessionRef(
                provider: provider,
                sessionID: try AppIntentProviderSupport.string("sessionID", in: object),
                transcriptPath: transcript.path,
                title: title
            ) else {
                throw AppIntentInputError.missingOrInvalidField("sessionID")
            }
            return .agentSession(ref)
        case "terminal":
            return .terminal
        case "changes":
            return .changes
        case "automation":
            return .automation
        case "empty":
            return .empty
        case "file":
            return .file(
                path: try AppIntentProviderSupport.string("path", in: object)
            )
        case "plugin":
            let pluginID = try PluginID(
                AppIntentProviderSupport.string("pluginID", in: object)
            )
            return .pluginView(
                pluginID: pluginID,
                viewID: try AppIntentProviderSupport.string(
                    "viewID",
                    in: object
                )
            )
        case "diff":
            let source = try AppIntentProviderSupport.string(
                "source",
                in: object
            )
            switch source {
            case "git":
                let repositoryPath = try AppIntentProviderSupport.string(
                    "repositoryPath",
                    in: object
                )
                let path = try AppIntentProviderSupport.string(
                    "path",
                    in: object
                )
                let staged = try AppIntentProviderSupport.bool(
                    "staged",
                    in: object
                )
                let untracked = try AppIntentProviderSupport.bool(
                    "untracked",
                    in: object
                )
                let originalPath: String?
                switch object["originalPath"] {
                case .none, .some(.null):
                    originalPath = nil
                case let .some(.string(value)):
                    originalPath = value
                default:
                    throw AppIntentInputError.missingOrInvalidField(
                        "originalPath"
                    )
                }
                let fileName = URL(
                    fileURLWithPath: path
                ).lastPathComponent
                return .diff(
                    DiffRequest(
                        source: .git(
                            repoPath: repositoryPath,
                            path: path,
                            staged: staged,
                            untracked: untracked,
                            origPath: originalPath
                        ),
                        fileName: fileName,
                        title: try AppIntentProviderSupport
                            .optionalString(
                                "title",
                                in: object
                            ) ?? fileName
                    )
                )
            case "inline":
                let fileName = try AppIntentProviderSupport.string(
                    "fileName",
                    in: object
                )
                return .diff(
                    DiffRequest(
                        source: .inline(
                            oldText: try AppIntentProviderSupport.string(
                                "oldText",
                                in: object
                            ),
                            newText: try AppIntentProviderSupport.string(
                                "newText",
                                in: object
                            )
                        ),
                        fileName: fileName,
                        title: try AppIntentProviderSupport
                            .optionalString(
                                "title",
                                in: object
                            ) ?? fileName
                    )
                )
            default:
                throw AppIntentInputError.missingOrInvalidField(
                    "source"
                )
            }
        default:
            throw AppIntentInputError.missingOrInvalidField("kind")
        }
    }
}

private extension WorkspaceIntentProvider {
    struct WorkspaceCursor: Equatable {
        let snapshotID: UUID
        let offset: Int
    }

    static func paneOwnerValue(
        catalog: WorkspaceCatalog,
        paneID: UUID
    ) -> IntentValue? {
        guard let owner = catalog.owner(ofSlot: paneID) else { return nil }
        return .object([
            "workspaceID": .string(owner.workspaceID.uuidString),
            "workspacePath": .string(owner.workspacePath.path),
            "tabID": .string(owner.tabID.uuidString),
        ])
    }

    static func identityValue(_ workspace: Workspace) -> IntentValue {
        let icon: IntentValue
        if let custom = workspace.appearance.customIcon {
            icon = .object([
                "kind": .string("custom"),
                "id": .string(custom.id.uuidString),
                "data": .string(custom.pngData.base64EncodedString()),
            ])
        } else {
            icon = .object([
                "kind": .string("symbol"),
                "name": .string(workspace.appearance.symbol.rawValue),
            ])
        }
        return .object([
            "workspaceID": .string(workspace.id.uuidString),
            "name": .string(workspace.name),
            "accent": .string(workspace.appearance.accent?.rawValue ?? "automatic"),
            "icon": icon,
        ])
    }

    static func snapshotPage(
        store: WorkspaceStore,
        offset: Int,
        limit: Int
    ) throws -> IntentValue {
        let nodes = snapshotNodes(store.catalog)
        guard offset >= 0, offset <= nodes.count else {
            throw AppIntentInputError.missingOrInvalidField("cursor")
        }

        var page: [IntentValue] = []
        var nextOffset = offset
        while nextOffset < nodes.count, page.count < limit {
            let candidateNodes = page + [nodes[nextOffset]]
            let candidateOffset = nextOffset + 1
            let candidate = snapshotValue(
                catalog: store.catalog,
                snapshotID: store.snapshotID,
                nodes: candidateNodes,
                nextOffset: candidateOffset < nodes.count
                    ? candidateOffset
                    : nil
            )
            do {
                try candidate.validate()
                page = candidateNodes
                nextOffset = candidateOffset
            } catch IntentValueError.maximumEncodedBytesExceeded {
                break
            } catch IntentValueError.maximumValueCountExceeded {
                break
            } catch IntentValueError.maximumCollectionCountExceeded {
                break
            }
        }

        guard nextOffset > offset || offset == nodes.count else {
            throw IntentValueError.maximumEncodedBytesExceeded(
                limit: IntentValueLimits.default.maxEncodedBytes
            )
        }
        let value = snapshotValue(
            catalog: store.catalog,
            snapshotID: store.snapshotID,
            nodes: page,
            nextOffset: nextOffset < nodes.count ? nextOffset : nil
        )
        try value.validate()
        return value
    }

    static func snapshotValue(
        catalog: WorkspaceCatalog,
        snapshotID: UUID,
        nodes: [IntentValue],
        nextOffset: Int?
    ) -> IntentValue {
        .object([
            "snapshotID": .string(snapshotID.uuidString),
            "activeWorkspaceID": .string(
                catalog.activeWorkspaceID.uuidString
            ),
            "activePaneID": catalog.activeSlotID
                .map { .string($0.uuidString) } ?? .null,
            "nodes": .array(nodes),
            "nextCursor": nextOffset.map {
                .string(
                    encodeCursor(
                        WorkspaceCursor(
                            snapshotID: snapshotID,
                            offset: $0
                        )
                    )
                )
            } ?? .null,
        ])
    }

    static func snapshotNodes(
        _ catalog: WorkspaceCatalog
    ) -> [IntentValue] {
        var nodes: [IntentValue] = []
        for workspace in catalog.workspaces {
            nodes.append(
                .object([
                    "kind": .string("workspace"),
                    "id": .string(workspace.id.uuidString),
                    "name": .string(workspace.name),
                    "path": .string(workspace.path.path),
                    "selected": .bool(
                        workspace.id == catalog.activeWorkspaceID
                    ),
                    "activeTabID": .string(
                        workspace.activeTabID.uuidString
                    ),
                ])
            )
            for tab in workspace.tabs {
                nodes.append(
                    .object([
                        "kind": .string("tab"),
                        "id": .string(tab.id.uuidString),
                        "workspaceID": .string(
                            workspace.id.uuidString
                        ),
                        "selected": .bool(
                            tab.id == workspace.activeTabID
                        ),
                        "activePaneID": tab.activeSlotID
                            .map { .string($0.uuidString) } ?? .null,
                    ])
                )
                for pane in tab.slots {
                    nodes.append(
                        .object([
                            "kind": .string("pane"),
                            "id": .string(pane.id.uuidString),
                            "tabID": .string(tab.id.uuidString),
                            "content": contentValue(pane.content),
                            "frame": .object([
                                "x": .integer(Int64(pane.rect.x)),
                                "y": .integer(Int64(pane.rect.y)),
                                "width": .integer(
                                    Int64(pane.rect.width)
                                ),
                                "height": .integer(
                                    Int64(pane.rect.height)
                                ),
                            ]),
                        ])
                    )
                }
            }
        }
        return nodes
    }

    static func encodeCursor(_ cursor: WorkspaceCursor) -> String {
        "\(cursor.snapshotID.uuidString.lowercased()):\(cursor.offset)"
    }

    static func decodeCursor(_ value: String) -> WorkspaceCursor? {
        let parts = value.split(
            separator: ":",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard parts.count == 2,
              let snapshotID = UUID(uuidString: String(parts[0])),
              let offset = Int(parts[1]),
              offset >= 0
        else {
            return nil
        }
        return WorkspaceCursor(
            snapshotID: snapshotID,
            offset: offset
        )
    }

    static func contentValue(_ content: SlotContent) -> IntentValue {
        switch content {
        case .terminal:
            .object(["kind": .string("terminal")])
        case .changes:
            .object(["kind": .string("changes")])
        case .automation:
            .object(["kind": .string("automation")])
        case .empty:
            .object(["kind": .string("empty")])
        case let .file(path):
            .object([
                "kind": .string("file"),
                "path": .string(path),
            ])
        case let .pluginView(plugin, viewID):
            .object([
                "kind": .string("plugin"),
                "pluginID": .string(plugin.rawValue),
                "viewID": .string(viewID),
            ])
        case let .diff(request):
            diffContentValue(request)
        case let .agentSession(ref):
            .object([
                "kind": .string("agentSession"),
                "provider": .string(ref.provider.rawValue),
                "sessionID": .string(ref.sessionID),
                "transcriptPath": .string(ref.transcriptPath),
                "title": ref.title.map(IntentValue.string) ?? .null,
            ])
        }
    }

    static func diffContentValue(_ request: DiffRequest) -> IntentValue {
        switch request.source {
        case let .git(repoPath, path, staged, untracked, originalPath):
            .object([
                "kind": .string("diff"),
                "source": .string("git"),
                "repositoryPath": .string(repoPath),
                "path": .string(path),
                "staged": .bool(staged),
                "untracked": .bool(untracked),
                "originalPath": originalPath
                    .map(IntentValue.string) ?? .null,
                "title": .string(request.title),
            ])
        case .inline:
            .object([
                "kind": .string("diff"),
                "source": .string("inline"),
                "fileName": .string(request.fileName),
                "title": .string(request.title),
            ])
        }
    }
}
