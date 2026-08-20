// @domain: intent-bus
import Foundation
import TenonIntentCore

/// The finite, canonical invocation vocabulary owned by Tenon.
///
/// This enum is the inventory boundary: adding or removing a core intent requires an
/// explicit source change and the catalog fitness tests require a matching definition.
/// Raw values are public protocol names, so every value is versioned from its first release.
public enum CoreIntentName: String, CaseIterable, Sendable, Hashable {
    case filesystemDirectoryList = "filesystem.directory.list.v2"
    case filesystemFileRead = "filesystem.file.read.v1"
    case filesystemPathExists = "filesystem.path.exists.v1"
    case filesystemFileWrite = "filesystem.file.write.v1"
    case filesystemDirectoryCreate = "filesystem.directory.create.v1"
    case filesystemFileCreate = "filesystem.file.create.v1"
    case filesystemPathMove = "filesystem.path.move.v1"
    case filesystemPathTrash = "filesystem.path.trash.v1"
    case fileReveal = "file.reveal.v1"
    case fileOpen = "file.open.v1"
    case urlOpen = "url.open.v1"
    case clipboardWrite = "clipboard.write.v1"
    case processExec = "process.exec.v1"
    case terminalWrite = "terminal.write.v1"
    case terminalRun = "terminal.run.v1"
    case terminalOpen = "terminal.open.v1"
    case terminalViewportRead = "terminal.viewport.read.v1"
    case terminalScrollbackRead = "terminal.scrollback.read.v1"
    case terminalProcessRead = "terminal.process.read.v1"
    case terminalWait = "terminal.wait.v1"
    case browserSurfaceLoad = "browser.surface.load.v1"
    case browserSurfaceBack = "browser.surface.back.v1"
    case browserSurfaceForward = "browser.surface.forward.v1"
    case browserSurfaceReload = "browser.surface.reload.v1"
    case uiPick = "ui.pick.v1"
    case uiPrompt = "ui.prompt.v1"
    case uiConfirm = "ui.confirm.v1"
    case uiToast = "ui.toast.v1"
    case secretsGet = "secrets.get.v1"
    case secretsSet = "secrets.set.v1"
    case secretsDelete = "secrets.delete.v1"
    case workspaceState = "workspace.state.v1"
    case workspaceIdentitySet = "workspace.identity.set.v1"
    case workspacePaneOwner = "workspace.pane.owner.v1"
    case workspaceTabCreate = "workspace.tab.create.v1"
    case workspaceTabFocus = "workspace.tab.focus.v1"
    case workspaceTabClose = "workspace.tab.close.v1"
    case workspacePaneSplit = "workspace.pane.split.v1"
    case workspacePaneFocus = "workspace.pane.focus.v1"
    case workspacePaneClose = "workspace.pane.close.v2"
    case workspacePaneContentSet = "workspace.pane.content.set.v1"
    case workspacePaneTitleSet = "workspace.pane.title.set.v1"
    case workspaceContentOpen = "workspace.content.open.v1"
    case workspaceTabNext = "workspace.tab.next.v1"
    case workspaceTabPrevious = "workspace.tab.previous.v1"
    case workspacePaneFocusNext = "workspace.pane.focus-next.v1"
    case workspaceSelect = "workspace.select.v1"
    case workspaceSleep = "workspace.sleep.v1"
    case workspaceVisibilitySet = "workspace.visibility.set.v1"
    case networkFetch = "network.fetch.v1"
    case agentInventory = "agent.inventory.v1"
    case agentCommand = "agent.command.v1"
    case agentAsk = "agent.ask.v1"

    public var intentID: IntentID {
        get throws {
            try IntentID(rawValue)
        }
    }
}

/// The only audience profiles available to core product contracts.
///
/// `CoreIntentName.audienceProfile` is an exhaustive switch so adding a core
/// intent cannot compile until its audience has been deliberately classified.
public enum CoreIntentAudienceProfile: Sendable, Equatable {
    case programmatic
    case pluginOnly

    public var audiences: Set<IntentAudience> {
        switch self {
        case .programmatic:
            [.plugin, .cli, .agent]
        case .pluginOnly:
            [.plugin]
        }
    }
}

public extension CoreIntentName {
    var audienceProfile: CoreIntentAudienceProfile {
        switch self {
        case .clipboardWrite,
             .browserSurfaceLoad,
             .browserSurfaceBack,
             .browserSurfaceForward,
             .browserSurfaceReload,
             .uiPick,
             .uiPrompt,
             .uiConfirm,
             .uiToast,
             .secretsGet,
             .secretsSet,
             .secretsDelete:
            .pluginOnly

        case .filesystemDirectoryList,
             .filesystemFileRead,
             .filesystemPathExists,
             .filesystemFileWrite,
             .filesystemDirectoryCreate,
             .filesystemFileCreate,
             .filesystemPathMove,
             .filesystemPathTrash,
             .fileReveal,
             .fileOpen,
             .urlOpen,
             .processExec,
             .terminalWrite,
             .terminalRun,
             .terminalOpen,
             .terminalViewportRead,
             .terminalScrollbackRead,
             .terminalProcessRead,
             .terminalWait,
             .workspaceState,
             .workspaceIdentitySet,
             .workspacePaneOwner,
             .workspaceTabCreate,
             .workspaceTabFocus,
             .workspaceTabClose,
             .workspacePaneSplit,
             .workspacePaneFocus,
             .workspacePaneClose,
             .workspacePaneContentSet,
             .workspacePaneTitleSet,
             .workspaceContentOpen,
             .workspaceTabNext,
             .workspaceTabPrevious,
             .workspacePaneFocusNext,
             .workspaceSelect,
             .workspaceSleep,
             .workspaceVisibilitySet,
             .networkFetch,
             .agentInventory,
             .agentCommand,
             .agentAsk:
            .programmatic
        }
    }
}

/// Physical execution isolation for the trusted core provider.
///
/// This is an exhaustive classification, not a public protocol. Every lane is
/// bounded and serial today; increasing capacity requires operation-specific
/// race and ordering tests instead of a global concurrency switch.
public enum CoreIntentExecutionLane: String, CaseIterable, Sendable, Hashable {
    case filesystem
    case system
    case process
    case network
    case workspace
    case terminalImmediate
    case terminalWait
    case browser
    case userPrompt
    case userNotification
    case secrets
    case agentImmediate
    case agentWait

    /// How many of this lane's intents may execute at once.
    ///
    /// Serial everywhere by default: a lane's mailbox is the unit of ordering and
    /// backpressure, and for work that mutates the workspace, writes a file, or drives a
    /// terminal, running one at a time is the property that makes the ordering mean
    /// something.
    ///
    /// `terminalWait` and `agentWait` are the exceptions, and they earn it. Their intents
    /// block on independent pane-owned conditions without holding the serial immediate
    /// mailbox. `terminalWait` waits on terminal state; `agentWait` waits on one declared
    /// question that is already bounded by both its own expiry and the dispatcher deadline.
    ///
    /// Specifically, `terminalWait`'s only intent is
    /// `terminal.wait.v1`, whose whole job is to block until a pane-scoped condition holds:
    /// waits are mutually independent, each scoped to its own pane, hold no resource, and
    /// have no meaningful order between them. Serializing them made supervising two agents
    /// impossible — the second wait queued behind the first, which by design does not
    /// return until met — measured and recorded as an open counterexample in
    /// `docs/architecture-interaction-boundaries.md`. The bound stays modest because
    /// supervision is human-scale: a person watches a handful of panes, not a thousand.
    public var maxConcurrentRequests: Int {
        switch self {
        case .terminalWait, .agentWait:
            8
        case .filesystem, .system, .process, .network, .workspace,
             .terminalImmediate, .browser, .userPrompt, .userNotification,
             .secrets, .agentImmediate:
            1
        }
    }
}

public extension CoreIntentName {
    var executionLane: CoreIntentExecutionLane {
        switch self {
        case .filesystemDirectoryList,
             .filesystemFileRead,
             .filesystemPathExists,
             .filesystemFileWrite,
             .filesystemDirectoryCreate,
             .filesystemFileCreate,
             .filesystemPathMove,
             .filesystemPathTrash:
            .filesystem

        case .fileReveal,
             .fileOpen,
             .urlOpen,
             .clipboardWrite:
            .system

        case .processExec:
            .process

        case .networkFetch:
            .network

        case .workspaceState,
             .workspaceIdentitySet,
             .workspacePaneOwner,
             .workspaceTabCreate,
             .workspaceTabFocus,
             .workspaceTabClose,
             .workspacePaneSplit,
             .workspacePaneFocus,
             .workspacePaneClose,
             .workspacePaneContentSet,
             .workspacePaneTitleSet,
             .workspaceContentOpen,
             .workspaceTabNext,
             .workspaceTabPrevious,
             .workspacePaneFocusNext,
             .workspaceSelect,
             .workspaceSleep,
             .workspaceVisibilitySet:
            .workspace

        case .terminalWrite,
             .terminalRun,
             .terminalOpen,
             .terminalViewportRead,
             .terminalScrollbackRead,
             .terminalProcessRead:
            .terminalImmediate

        case .terminalWait:
            .terminalWait

        case .browserSurfaceLoad,
             .browserSurfaceBack,
             .browserSurfaceForward,
             .browserSurfaceReload:
            .browser

        case .uiPick,
             .uiPrompt,
             .uiConfirm:
            .userPrompt

        case .uiToast:
            .userNotification

        case .secretsGet,
             .secretsSet,
             .secretsDelete:
            .secrets

        case .agentInventory,
             .agentCommand:
            .agentImmediate

        case .agentAsk:
            .agentWait
        }
    }
}
