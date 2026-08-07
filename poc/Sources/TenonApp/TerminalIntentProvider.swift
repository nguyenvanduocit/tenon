// @domain: intent-bus, terminal-surface
import Foundation
import TenonCore
import TenonIntentCore

private enum TerminalWaitCondition: String, Sendable {
    case exit
    case tuiIdle = "tui-idle"
    case commandFinished = "command-finished"
}

@MainActor
final class TerminalIntentProvider {
    /// Chosen so an unparameterised read answers with a screenful of history rather than
    /// the whole buffer; a caller that wants more says so, up to the contract's bound.
    static let defaultScrollbackPageLines = 500
    static let defaultWaitMilliseconds = 30_000
    static let maximumWaitMilliseconds = 55_000

    private let store: WorkspaceStore
    private let surfaces: SurfacePool
    private let unavailable: IntentErrorCode

    init(store: WorkspaceStore, surfaces: SurfacePool) throws {
        self.store = store
        self.surfaces = surfaces
        unavailable = .domain(
            try IntentDomainErrorCode("dev.tenon.core.terminal-unavailable")
        )
    }

    func bindings() throws -> [IntentProviderBinding] {
        [
            IntentProviderBinding(
                intentID: try CoreIntentName.terminalWrite.intentID
            ) { envelope, context in
                try context.checkCancellation()
                let reply = await self.write(envelope: envelope)
                try context.checkCancellation()
                return reply
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.terminalRun.intentID
            ) { envelope, context in
                try context.checkCancellation()
                let reply = await self.run(envelope: envelope)
                try context.checkCancellation()
                return reply
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.terminalOpen.intentID
            ) { envelope, context in
                try context.checkCancellation()
                let reply = await self.open(envelope: envelope)
                try context.checkCancellation()
                return reply
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.terminalViewportRead.intentID
            ) { envelope, context in
                try context.checkCancellation()
                let reply = await self.readViewport(envelope: envelope)
                try context.checkCancellation()
                return reply
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.terminalScrollbackRead.intentID
            ) { envelope, context in
                try context.checkCancellation()
                let reply = await self.readScrollback(envelope: envelope)
                try context.checkCancellation()
                return reply
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.terminalWait.intentID
            ) { envelope, context in
                try context.checkCancellation()
                let reply = try await self.wait(
                    envelope: envelope,
                    context: context
                )
                try context.checkCancellation()
                return reply
            },
        ]
    }
}

private extension TerminalIntentProvider {
    enum Target {
        case resolved(UUID)
        case unavailable(String)
    }

    func write(envelope: IntentEnvelope) -> IntentProviderReply {
        do {
            let object = try AppIntentProviderSupport.object(envelope.input)
            let text = try AppIntentProviderSupport.string("text", in: object)
            switch PaneTarget.resolve(
                explicit: envelope.scope.paneID,
                in: store.catalog,
                requireTerminal: true
            ) {
            case let .resolved(paneID):
                surfaces.sendTextWhenReady(text, to: paneID)
                return AppIntentProviderSupport.emptySuccess
            case .paneNotFound:
                return failure("pane-scope-not-found")
            case .notATerminal:
                return failure("pane-is-not-a-terminal")
            case .noActivePane:
                return failure("active-terminal-not-found")
            }
        } catch let error as AppIntentInputError {
            return AppIntentProviderSupport.invalidInput(error)
        } catch {
            return AppIntentProviderSupport.invalidInput(
                .missingOrInvalidField("$")
            )
        }
    }

    func run(envelope: IntentEnvelope) -> IntentProviderReply {
        do {
            let object = try AppIntentProviderSupport.object(envelope.input)
            let command = try AppIntentProviderSupport.string(
                "command",
                in: object
            )
            guard !command
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
                !command.contains("\0")
            else {
                throw AppIntentInputError.missingOrInvalidField("command")
            }

            let paneID: UUID
            if let preferred = preferredTerminal(for: envelope.scope) {
                paneID = preferred
                store.focusSlot(preferred)
            } else {
                guard selectWorkspace(for: envelope.scope) else {
                    return failure("workspace-scope-not-found")
                }
                store.newTab(content: .terminal)
                guard let created = store.catalog.activeSlotID,
                      store.catalog.slot(id: created)?.content == .terminal
                else {
                    return failure("terminal-create-failed")
                }
                paneID = created
            }

            surfaces.sendTextWhenReady(command + "\n", to: paneID)
            return AppIntentProviderSupport.emptySuccess
        } catch let error as AppIntentInputError {
            return AppIntentProviderSupport.invalidInput(error)
        } catch {
            return AppIntentProviderSupport.invalidInput(
                .missingOrInvalidField("$")
            )
        }
    }

    /// `terminal.open.v1` — always a fresh pane, and it says which one.
    ///
    /// `terminal.run.v1` reuses a terminal in scope and only creates a tab when there is
    /// none, which is right for "run this somewhere" and wrong for "run this on its own".
    /// The two share every other rule: the same capability, the same delivery through
    /// `sendTextWhenReady`, and the same lane.
    func open(envelope: IntentEnvelope) -> IntentProviderReply {
        let command: String?
        let workingDirectory: URL?
        do {
            let input = try AppIntentProviderSupport.object(envelope.input)
            if let raw = try AppIntentProviderSupport.optionalString(
                "command",
                in: input
            ) {
                guard !raw
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty,
                    !raw.contains("\0")
                else {
                    throw AppIntentInputError.missingOrInvalidField("command")
                }
                command = raw
            } else {
                command = nil
            }

            if let raw = try AppIntentProviderSupport.optionalString(
                "workingDirectory",
                in: input
            ) {
                // Refused rather than accepted-and-ignored: a shell that cannot enter the
                // directory would start somewhere else, and the caller would never learn
                // its command ran in the wrong place.
                var isDirectory: ObjCBool = false
                guard raw.hasPrefix("/"),
                      FileManager.default.fileExists(
                          atPath: raw,
                          isDirectory: &isDirectory
                      ),
                      isDirectory.boolValue
                else {
                    throw AppIntentInputError.missingOrInvalidField(
                        "workingDirectory"
                    )
                }
                workingDirectory = URL(fileURLWithPath: raw, isDirectory: true)
            } else {
                workingDirectory = nil
            }
        } catch let error as AppIntentInputError {
            return AppIntentProviderSupport.invalidInput(error)
        } catch {
            return AppIntentProviderSupport.invalidInput(.expectedObject)
        }

        guard selectWorkspace(for: envelope.scope) else {
            return failure("workspace-scope-not-found")
        }
        store.newTab(content: .terminal)
        guard let paneID = store.catalog.activeSlotID,
              store.catalog.slot(id: paneID)?.content == .terminal
        else {
            return failure("terminal-create-failed")
        }

        // Before any text: the pane has no surface yet, so this decides where its shell
        // starts rather than trying to move a shell that is already running.
        if let workingDirectory {
            surfaces.seedSpawnDirectory(workingDirectory, for: paneID)
        }
        if let command {
            surfaces.sendTextWhenReady(command + "\n", to: paneID)
        }
        return .success(
            .object(["paneID": .string(paneID.uuidString)])
        )
    }

    func readViewport(envelope: IntentEnvelope) -> IntentProviderReply {
        guard envelope.input == .object([:]) else {
            return AppIntentProviderSupport.invalidInput(.expectedObject)
        }
        switch terminalTarget(for: envelope.scope) {
        case let .unavailable(reason):
            return failure(reason)
        case let .resolved(paneID):
            guard let observation = surfaces.terminalObservation(
                for: paneID
            ) else {
                return failure("terminal-surface-not-ready")
            }
            guard isInline(observation.text) else {
                return failure("terminal-viewport-inline-limit-exceeded")
            }
            return .success(
                .object([
                    "paneID": .string(paneID.uuidString),
                    "text": .string(observation.text),
                    "exited": .bool(observation.processExited),
                    "columns": observation.columns.map {
                        .integer(Int64($0))
                    } ?? .null,
                    "rows": observation.rows.map {
                        .integer(Int64($0))
                    } ?? .null,
                ])
            )
        }
    }

    /// One bounded page of retained scrollback. The decision of *which* rows is
    /// `ScrollbackPaging`'s, so everything here is edge work: parse, resolve the pane, ask
    /// the surface what it holds, and turn the pure verdict into a reply.
    func readScrollback(envelope: IntentEnvelope) -> IntentProviderReply {
        let maxLines: Int
        let cursor: ScrollbackPaging.Cursor?
        do {
            let input = try AppIntentProviderSupport.object(envelope.input)
            maxLines = try AppIntentProviderSupport.optionalInteger(
                "maxLines",
                in: input
            ) ?? Self.defaultScrollbackPageLines
            guard (1 ... CoreIntentPayloadPolicy.maximumScrollbackPageLines)
                .contains(maxLines)
            else {
                throw AppIntentInputError.missingOrInvalidField("maxLines")
            }
            if let raw = try AppIntentProviderSupport.optionalString(
                "cursor",
                in: input
            ) {
                guard let decoded = ScrollbackPaging.Cursor.decode(raw) else {
                    throw AppIntentInputError.missingOrInvalidField("cursor")
                }
                cursor = decoded
            } else {
                cursor = nil
            }
        } catch let error as AppIntentInputError {
            return AppIntentProviderSupport.invalidInput(error)
        } catch {
            return AppIntentProviderSupport.invalidInput(.expectedObject)
        }

        let paneID: UUID
        switch terminalTarget(for: envelope.scope) {
        case let .unavailable(reason):
            return failure(reason)
        case let .resolved(resolved):
            paneID = resolved
        }
        guard let lines = surfaces.scrollbackLines(for: paneID) else {
            return failure("terminal-surface-not-ready")
        }

        switch ScrollbackPaging.page(
            totalRows: lines.count,
            maxLines: maxLines,
            cursor: cursor
        ) {
        case .invalidated:
            return .success(
                .object([
                    "paneID": .string(paneID.uuidString),
                    "text": .string(""),
                    "cursor": .null,
                    "invalidated": .bool(true),
                    "totalRows": .integer(Int64(lines.count)),
                ])
            )
        case let .rows(range, next):
            let text = lines[range].joined(separator: "\n")
            guard isInline(text) else {
                return failure("terminal-scrollback-inline-limit-exceeded")
            }
            return .success(
                .object([
                    "paneID": .string(paneID.uuidString),
                    "text": .string(text),
                    "cursor": next.map { .string($0.encoded) } ?? .null,
                    "invalidated": .bool(false),
                    "totalRows": .integer(Int64(lines.count)),
                ])
            )
        }
    }

    func wait(
        envelope: IntentEnvelope,
        context: IntentProviderContext
    ) async throws -> IntentProviderReply {
        let input: [String: IntentValue]
        let condition: TerminalWaitCondition
        let timeoutMilliseconds: Int
        do {
            input = try AppIntentProviderSupport.object(envelope.input)
            let rawCondition = try AppIntentProviderSupport.string(
                "condition",
                in: input
            )
            guard let parsed = TerminalWaitCondition(
                rawValue: rawCondition
            ) else {
                throw AppIntentInputError.missingOrInvalidField(
                    "condition"
                )
            }
            condition = parsed
            timeoutMilliseconds =
                try AppIntentProviderSupport.optionalInteger(
                    "timeoutMs",
                    in: input
                ) ?? Self.defaultWaitMilliseconds
            guard (1 ... Self.maximumWaitMilliseconds).contains(
                timeoutMilliseconds
            ) else {
                throw AppIntentInputError.missingOrInvalidField(
                    "timeoutMs"
                )
            }
        } catch let error as AppIntentInputError {
            return AppIntentProviderSupport.invalidInput(error)
        }

        let paneID: UUID
        switch terminalTarget(for: envelope.scope) {
        case let .unavailable(reason):
            return failure(reason)
        case let .resolved(resolved):
            paneID = resolved
        }

        let clock = ContinuousClock()
        let waitDeadline = clock.now.advanced(
            by: .milliseconds(timeoutMilliseconds)
        )
        var detector = IdleDetector(stableSamples: 3)
        let baseline = surfaces.terminalObservation(
            for: paneID
        )?.commandFinishedCount ?? 0

        while true {
            try context.checkCancellation()
            guard clock.now < envelope.deadline else {
                return .failure(
                    IntentProviderFailure(
                        code: .kernel(.deadlineExceeded)
                    )
                )
            }

            if let observation = surfaces.terminalObservation(
                for: paneID
            ) {
                let met: Bool
                switch condition {
                case .exit:
                    met = observation.processExited
                case .tuiIdle:
                    met = observation.processExited
                        || detector.record(observation.text)
                case .commandFinished:
                    met = observation.commandFinishedCount > baseline
                }
                if met {
                    return waitResult(
                        paneID: paneID,
                        condition: condition,
                        met: true
                    )
                }
                if condition == .commandFinished,
                   observation.processExited
                {
                    return waitResult(
                        paneID: paneID,
                        condition: condition,
                        met: false
                    )
                }
            }

            let now = clock.now
            guard now < waitDeadline else {
                return waitResult(
                    paneID: paneID,
                    condition: condition,
                    met: false
                )
            }
            let nextPoll = now.advanced(by: .milliseconds(200))
            try await clock.sleep(
                until: min(
                    nextPoll,
                    min(waitDeadline, envelope.deadline)
                ),
                tolerance: .milliseconds(20)
            )
        }
    }

    func waitResult(
        paneID: UUID,
        condition: TerminalWaitCondition,
        met: Bool
    ) -> IntentProviderReply {
        .success(
            .object([
                "paneID": .string(paneID.uuidString),
                "condition": .string(condition.rawValue),
                "met": .bool(met),
            ])
        )
    }

    func terminalTarget(for scope: InvocationScope) -> Target {
        switch PaneTarget.resolve(
            explicit: scope.paneID,
            in: store.catalog,
            requireTerminal: true
        ) {
        case let .resolved(paneID):
            return .resolved(paneID)
        case .paneNotFound:
            return .unavailable("pane-scope-not-found")
        case .notATerminal:
            return .unavailable("pane-is-not-a-terminal")
        case .noActivePane:
            return .unavailable("active-terminal-not-found")
        }
    }

    func isInline(_ text: String) -> Bool {
        text.count
            <= CoreIntentPayloadPolicy.maximumInlineTextCharacters
            && text.utf8.count
                <= CoreIntentPayloadPolicy.maximumInlineTextCharacters
    }

    func preferredTerminal(for scope: InvocationScope) -> UUID? {
        if let paneID = scope.paneID,
           store.catalog.slot(id: paneID)?.content == .terminal
        {
            return paneID
        }

        let workspace: Workspace?
        if let workspaceID = scope.workspaceID {
            workspace = store.catalog.workspaces.first {
                $0.id == workspaceID
            }
        } else if let paneID = scope.paneID {
            workspace = store.catalog.workspaces.first { workspace in
                workspace.tabs.contains { tab in
                    tab.slots.contains { $0.id == paneID }
                }
            }
        } else {
            workspace = store.catalog.activeWorkspace
        }
        guard let workspace else {
            return nil
        }

        let preferredTab: Tab?
        if let paneID = scope.paneID {
            preferredTab = workspace.tabs.first { tab in
                tab.slots.contains { $0.id == paneID }
            }
        } else {
            preferredTab = workspace.activeTab
        }

        if let preferredTab {
            if let activePaneID = preferredTab.activeSlotID,
               preferredTab.slots.first(where: {
                   $0.id == activePaneID
               })?.content == .terminal
            {
                return activePaneID
            }
            if let inTab = preferredTab.slots.first(where: {
                $0.content == .terminal
            }) {
                return inTab.id
            }
        }

        for tab in workspace.tabs where tab.id != preferredTab?.id {
            if let pane = tab.slots.first(where: {
                $0.content == .terminal
            }) {
                return pane.id
            }
        }
        return nil
    }

    func selectWorkspace(for scope: InvocationScope) -> Bool {
        let workspaceID: UUID?
        if let scoped = scope.workspaceID {
            workspaceID = scoped
        } else if let paneID = scope.paneID {
            workspaceID = store.catalog.workspaces.first { workspace in
                workspace.tabs.contains { tab in
                    tab.slots.contains { $0.id == paneID }
                }
            }?.id
        } else {
            workspaceID = store.catalog.activeWorkspaceID
        }
        guard let workspaceID,
              store.catalog.workspaces.contains(where: {
                  $0.id == workspaceID
              })
        else {
            return false
        }
        store.selectWorkspace(workspaceID)
        return store.catalog.activeWorkspaceID == workspaceID
    }

    func failure(_ reason: String) -> IntentProviderReply {
        AppIntentProviderSupport.failure(
            code: unavailable,
            reason: reason
        )
    }
}
