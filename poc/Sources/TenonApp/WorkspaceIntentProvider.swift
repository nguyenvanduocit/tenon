import Foundation
import TenonCore
import TenonIntentCore

@MainActor
final class WorkspaceIntentProvider {
    private struct ErrorCodes {
        let workspaceUnavailable: IntentErrorCode
        let workspaceNotFound: IntentErrorCode
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

    init(store: WorkspaceStore) throws {
        self.store = store
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
                intentID: try CoreIntentName.workspaceTabCreate.intentID
            ) { envelope, context in
                try context.checkCancellation()
                return await self.createTab(envelope: envelope)
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

    func createTab(envelope: IntentEnvelope) -> IntentProviderReply {
        do {
            let object = try AppIntentProviderSupport.object(envelope.input)
            let content = try object["content"].map(Self.content(from:))
            if NewTabLauncherPlacement.consumeReservedTabCreation(
                scope: envelope.scope,
                content: content,
                store: store
            ) {
                return AppIntentProviderSupport.emptySuccess
            }

            guard selectScopedWorkspace(envelope.scope) else {
                return failure(
                    codes.workspaceNotFound,
                    reason: "workspace-scope-not-found"
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

    /// Places content without the caller choosing a pane: the pane already showing this
    /// kind of content takes it, and otherwise one is split beside. The scope pane names
    /// the tab; a scope without a pane opens into the scoped workspace's active tab.
    func openContent(envelope: IntentEnvelope) -> IntentProviderReply {
        do {
            let object = try AppIntentProviderSupport.object(envelope.input)
            guard let value = object["content"] else {
                throw AppIntentInputError.missingOrInvalidField("content")
            }
            let content = try Self.content(from: value)

            if let paneID = envelope.scope.paneID {
                guard store.catalog.slot(id: paneID) != nil else {
                    return failure(
                        codes.paneNotFound,
                        reason: "pane-scope-not-found"
                    )
                }
                store.focusSlot(paneID)
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
        guard selectScopedWorkspace(envelope.scope) else {
            return failure(
                codes.workspaceNotFound,
                reason: "workspace-scope-not-found"
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
        guard let workspaceID = scope.workspaceID else {
            return store.catalog.activeWorkspace != nil
        }
        guard store.catalog.workspaces.contains(where: { $0.id == workspaceID }) else {
            return false
        }
        store.selectWorkspace(workspaceID)
        return store.catalog.activeWorkspaceID == workspaceID
    }

    func failure(
        _ code: IntentErrorCode,
        reason: String
    ) -> IntentProviderReply {
        AppIntentProviderSupport.failure(code: code, reason: reason)
    }

    static func content(from value: IntentValue) throws -> SlotContent {
        let object = try AppIntentProviderSupport.object(value)
        let kind = try AppIntentProviderSupport.string("kind", in: object)
        switch kind {
        case "terminal":
            return .terminal
        case "changes":
            return .changes
        case "docs":
            return .docs
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

    struct WorkspaceCursor: Equatable {
        let snapshotID: UUID
        let offset: Int
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
        case .docs:
            .object(["kind": .string("docs")])
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
