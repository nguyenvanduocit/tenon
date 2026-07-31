import Foundation
import TenonIntentCore

/// The finite, canonical invocation vocabulary owned by Tenon.
///
/// This enum is the inventory boundary: adding or removing a core intent requires an
/// explicit source change and the catalog fitness tests require a matching definition.
/// Raw values are public protocol names, so every value is versioned from its first release.
public enum CoreIntentName: String, CaseIterable, Sendable, Hashable {
    case filesystemDirectoryList = "filesystem.directory.list.v1"
    case filesystemFileRead = "filesystem.file.read.v1"
    case filesystemPathExists = "filesystem.path.exists.v1"
    case filesystemFileWrite = "filesystem.file.write.v1"
    case filesystemDirectoryCreate = "filesystem.directory.create.v1"
    case filesystemFileCreate = "filesystem.file.create.v1"
    case filesystemPathMove = "filesystem.path.move.v1"
    case filesystemPathTrash = "filesystem.path.trash.v1"
    case fileReveal = "file.reveal.v1"
    case fileOpen = "file.open.v1"
    case clipboardWrite = "clipboard.write.v1"
    case processExec = "process.exec.v1"
    case terminalWrite = "terminal.write.v1"
    case terminalRun = "terminal.run.v1"
    case terminalOpen = "terminal.open.v1"
    case terminalViewportRead = "terminal.viewport.read.v1"
    case terminalScrollbackRead = "terminal.scrollback.read.v1"
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
    case workspaceTabCreate = "workspace.tab.create.v1"
    case workspacePaneSplit = "workspace.pane.split.v1"
    case workspacePaneFocus = "workspace.pane.focus.v1"
    case workspacePaneClose = "workspace.pane.close.v1"
    case workspacePaneContentSet = "workspace.pane.content.set.v1"
    case workspaceContentOpen = "workspace.content.open.v1"
    case workspaceTabNext = "workspace.tab.next.v1"
    case workspaceTabPrevious = "workspace.tab.previous.v1"
    case workspacePaneFocusNext = "workspace.pane.focus-next.v1"
    case workspaceSelect = "workspace.select.v1"
    case networkFetch = "network.fetch.v1"

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
             .processExec,
             .terminalWrite,
             .terminalRun,
             .terminalOpen,
             .terminalViewportRead,
             .terminalScrollbackRead,
             .terminalWait,
             .workspaceState,
             .workspaceTabCreate,
             .workspacePaneSplit,
             .workspacePaneFocus,
             .workspacePaneClose,
             .workspacePaneContentSet,
             .workspaceContentOpen,
             .workspaceTabNext,
             .workspaceTabPrevious,
             .workspacePaneFocusNext,
             .workspaceSelect,
             .networkFetch:
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

    /// How many of this lane's intents may execute at once.
    ///
    /// Serial everywhere by default: a lane's mailbox is the unit of ordering and
    /// backpressure, and for work that mutates the workspace, writes a file, or drives a
    /// terminal, running one at a time is the property that makes the ordering mean
    /// something.
    ///
    /// `terminalWait` is the exception, and it earns it. Its only intent is
    /// `terminal.wait.v1`, whose whole job is to block until a pane-scoped condition holds:
    /// waits are mutually independent, each scoped to its own pane, hold no resource, and
    /// have no meaningful order between them. Serializing them made supervising two agents
    /// impossible — the second wait queued behind the first, which by design does not
    /// return until met — measured and recorded as an open counterexample in
    /// `docs/architecture-interaction-boundaries.md`. The bound stays modest because
    /// supervision is human-scale: a person watches a handful of panes, not a thousand.
    public var maxConcurrentRequests: Int {
        switch self {
        case .terminalWait:
            8
        case .filesystem, .system, .process, .network, .workspace,
             .terminalImmediate, .browser, .userPrompt, .userNotification,
             .secrets:
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
             .clipboardWrite:
            .system

        case .processExec:
            .process

        case .networkFetch:
            .network

        case .workspaceState,
             .workspaceTabCreate,
             .workspacePaneSplit,
             .workspacePaneFocus,
             .workspacePaneClose,
             .workspacePaneContentSet,
             .workspaceContentOpen,
             .workspaceTabNext,
             .workspaceTabPrevious,
             .workspacePaneFocusNext,
             .workspaceSelect:
            .workspace

        case .terminalWrite,
             .terminalRun,
             .terminalOpen,
             .terminalViewportRead,
             .terminalScrollbackRead:
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
        }
    }
}

/// Host-wide bounds shared by every v1 core intent.
///
/// Inline text is deliberately below the envelope limit so its object metadata
/// still fits. V1 contracts fail explicitly when content cannot fit inline;
/// resource transport will be introduced only with a real resource lifecycle.
public enum CoreIntentPayloadPolicy {
    public static let maximumEncodedBytes = IntentValueLimits.default.maxEncodedBytes
    public static let hardMaximumEncodedBytes =
        IntentValueLimits.hardMaximumEncodedBytes
    public static let maximumInlineTextCharacters = 48 * 1024

    /// Rows a single `terminal.scrollback.read.v1` page may carry. A page also has to fit
    /// `maximumInlineTextCharacters`, so this is the row-count half of a two-sided bound:
    /// whichever runs out first ends the page, and the cursor carries the rest.
    public static let maximumScrollbackPageLines = 2_000

    /// The cursor is `"<nextRow>:<totalRows>"` — two decimal integers and a colon. The
    /// bound exists so a caller cannot hand back an unbounded string and make the host
    /// parse it.
    public static let maximumScrollbackCursorCharacters = 64
}

/// One row in the canonical table. The declaration describes the public contract; the rule
/// describes host-owned routing, authority, exposure, admission, and resource bounds.
public struct CoreIntentDefinition: Sendable, Equatable {
    public let declaration: IntentContractDeclaration
    public let dispatchRule: IntentDispatchRule

    public init(
        declaration: IntentContractDeclaration,
        dispatchRule: IntentDispatchRule
    ) {
        self.declaration = declaration
        self.dispatchRule = dispatchRule
    }
}

/// The immutable result of compiling the core table.
public struct CompiledCoreIntentCatalog: Sendable, Equatable {
    public let trustedProviderID: ProviderID
    public let definitions: [CoreIntentDefinition]
    public let contractSnapshot: ContractCatalogSnapshot
    public let dispatcherRuleRevision: UInt64
    public let dispatchRules: [IntentID: IntentDispatchRule]

    public init(
        trustedProviderID: ProviderID,
        definitions: [CoreIntentDefinition],
        contractSnapshot: ContractCatalogSnapshot,
        dispatcherRuleRevision: UInt64,
        dispatchRules: [IntentID: IntentDispatchRule]
    ) {
        self.trustedProviderID = trustedProviderID
        self.definitions = definitions
        self.contractSnapshot = contractSnapshot
        self.dispatcherRuleRevision = dispatcherRuleRevision
        self.dispatchRules = dispatchRules
    }

    public func rule(for intentID: IntentID) -> IntentDispatchRule? {
        dispatchRules[intentID]
    }
}

public enum CoreIntentCatalogError: Error, Sendable, Equatable {
    case inventoryMismatch(expected: Int, actual: Int)
    case duplicateIntentID(String)
    case ruleIntentMismatch(declaration: String, rule: String)
    case trustedProviderMismatch(intent: String)
    case exposureOutsideAudience(intent: String, audience: IntentAudience)
    case invalidPayloadLimit(intent: String, maximumEncodedBytes: Int)
    case authoritativeContractMissing(String)
    case authoritativeRuleMismatch(String)
}

/// Installs and caches the canonical table once in one authoritative kernel.
///
/// The in-flight task is installed before the first suspension, so concurrent callers share
/// the same schema compilation and rule registration rather than racing independent installs.
public actor CoreIntentCatalog {
    public static let trustedProviderIDRawValue = "dev.tenon.core"

    private let catalog: ContractCatalog
    private let dispatcher: IntentDispatcher
    private var compiled: CompiledCoreIntentCatalog?
    private var compilationTask: Task<CompiledCoreIntentCatalog, any Error>?
    internal private(set) var compilationCount = 0

    /// Binds this loader to the kernel composition root whose catalog and dispatcher are
    /// authoritative for production. Keeping both references from one component value avoids
    /// accidentally registering rules against a dispatcher backed by a different catalog.
    public init(components: IntentKernelComponents) {
        catalog = components.catalog
        dispatcher = components.dispatcher
    }

    public static func trustedProviderID() throws -> ProviderID {
        try ProviderID(trustedProviderIDRawValue)
    }

    /// Returns the declarative table without compiling validators.
    public static func definitions() throws -> [CoreIntentDefinition] {
        try makeDefinitions(trustedProviderID: trustedProviderID())
    }

    public func install() async throws -> CompiledCoreIntentCatalog {
        if let compiled {
            return compiled
        }
        if let compilationTask {
            return try await compilationTask.value
        }

        compilationCount += 1
        let catalog = catalog
        let dispatcher = dispatcher
        let task = Task {
            try await Self.installCatalog(
                into: catalog,
                dispatcher: dispatcher
            )
        }
        compilationTask = task

        do {
            let value = try await task.value
            compiled = value
            compilationTask = nil
            return value
        } catch {
            compilationTask = nil
            throw error
        }
    }
}

private extension CoreIntentCatalog {
    static func installCatalog(
        into catalog: ContractCatalog,
        dispatcher: IntentDispatcher
    ) async throws -> CompiledCoreIntentCatalog {
        let trustedProviderID = try trustedProviderID()
        let definitions = try makeDefinitions(trustedProviderID: trustedProviderID)
        let expectedIDs = try Set(CoreIntentName.allCases.map { try $0.intentID })
        let actualIDs = Set(definitions.map(\.declaration.name))
        guard definitions.count == CoreIntentName.allCases.count,
              actualIDs == expectedIDs
        else {
            throw CoreIntentCatalogError.inventoryMismatch(
                expected: CoreIntentName.allCases.count,
                actual: definitions.count
            )
        }

        var rules: [IntentID: IntentDispatchRule] = [:]
        rules.reserveCapacity(definitions.count)

        for definition in definitions {
            let declaration = definition.declaration
            let rule = definition.dispatchRule
            guard declaration.name == rule.intentID else {
                throw CoreIntentCatalogError.ruleIntentMismatch(
                    declaration: declaration.name.rawValue,
                    rule: rule.intentID.rawValue
                )
            }
            guard rule.trustedDefault == trustedProviderID else {
                throw CoreIntentCatalogError.trustedProviderMismatch(
                    intent: declaration.name.rawValue
                )
            }
            for audience in rule.exposure.discoverableBy.union(rule.exposure.invocableBy)
                where !declaration.audiences.contains(audience)
            {
                throw CoreIntentCatalogError.exposureOutsideAudience(
                    intent: declaration.name.rawValue,
                    audience: audience
                )
            }
            guard rule.valueLimits.maxEncodedBytes
                == CoreIntentPayloadPolicy.maximumEncodedBytes,
                rule.valueLimits.maxEncodedBytes
                <= CoreIntentPayloadPolicy.hardMaximumEncodedBytes
            else {
                throw CoreIntentCatalogError.invalidPayloadLimit(
                    intent: declaration.name.rawValue,
                    maximumEncodedBytes: rule.valueLimits.maxEncodedBytes
                )
            }
            guard rules[declaration.name] == nil else {
                throw CoreIntentCatalogError.duplicateIntentID(
                    declaration.name.rawValue
                )
            }

            rules[declaration.name] = rule
            try await catalog.register(declaration)
        }

        for definition in definitions {
            try await dispatcher.registerRule(definition.dispatchRule)
        }

        let contractSnapshot = await catalog.snapshot
        let dispatcherSnapshot = await dispatcher.snapshot()
        var authoritativeRules: [IntentID: IntentDispatchRule] = [:]
        authoritativeRules.reserveCapacity(definitions.count)
        for definition in definitions {
            let intentID = definition.declaration.name
            guard contractSnapshot.contract(named: intentID) != nil else {
                throw CoreIntentCatalogError.authoritativeContractMissing(
                    intentID.rawValue
                )
            }
            guard dispatcherSnapshot.rules[intentID]
                == definition.dispatchRule
            else {
                throw CoreIntentCatalogError.authoritativeRuleMismatch(
                    intentID.rawValue
                )
            }
            authoritativeRules[intentID] = definition.dispatchRule
        }

        return CompiledCoreIntentCatalog(
            trustedProviderID: trustedProviderID,
            definitions: definitions,
            contractSnapshot: contractSnapshot,
            dispatcherRuleRevision: dispatcherSnapshot.ruleRevision,
            dispatchRules: authoritativeRules
        )
    }

    static func makeDefinitions(
        trustedProviderID: ProviderID
    ) throws -> [CoreIntentDefinition] {
        let programmatic = CoreIntentAudienceProfile.programmatic.audiences
        let pluginOnly = CoreIntentAudienceProfile.pluginOnly.audiences

        let programmaticExposure = CoreIntentRuleData.exposure(programmatic)
        let pluginOnlyExposure = CoreIntentRuleData.exposure(pluginOnly)

        let filesystemReadPath = try CoreIntentRuleData.binding(
            capability: "filesystem.read",
            filesystemPaths: ["/path"]
        )
        let filesystemWritePath = try CoreIntentRuleData.binding(
            capability: "filesystem.write",
            filesystemPaths: ["/path"]
        )
        let filesystemMovePaths = try CoreIntentRuleData.binding(
            capability: "filesystem.write",
            filesystemPaths: ["/sourcePath", "/destinationPath"]
        )
        let shellOpenPath = try CoreIntentRuleData.binding(
            capability: "shell.open",
            filesystemPaths: ["/path"]
        )
        // `process.exec` is intentionally one unsandboxed local-process authority. A child
        // can access the invoking user's files and network through argv or its own syscalls,
        // so filesystem path bindings would imply confinement the host does not enforce.
        let processExec = try CoreIntentRuleData.binding(
            capability: "process.exec"
        )
        let terminalWrite = try CoreIntentRuleData.binding(capability: "terminal.write")
        let terminalRead = try CoreIntentRuleData.binding(
            capability: "terminal.read"
        )
        let webView = try CoreIntentRuleData.binding(capability: "web.view")
        let webViewURL = try CoreIntentRuleData.binding(
            capability: "web.view",
            networkURLs: ["/url"]
        )
        let secrets = try CoreIntentRuleData.binding(capability: "secrets")
        let workspaceControl = try CoreIntentRuleData.binding(
            capability: "workspace.control"
        )
        let networkURL = try CoreIntentRuleData.binding(
            capability: "network",
            networkURLs: ["/url"]
        )

        let emptyInput = CoreIntentSchema.root()
        let emptyOutput = CoreIntentSchema.root()
        let pathInput = CoreIntentSchema.root(
            properties: ["path": CoreIntentSchema.path],
            required: ["path"]
        )
        let pathOutput = CoreIntentSchema.root(
            properties: ["path": CoreIntentSchema.path],
            required: ["path"]
        )

        return [
            try CoreIntentRuleData.definition(
                .filesystemDirectoryList,
                title: "List directory",
                description: "Returns one bounded, cursor-addressable page of directory entries.",
                input: CoreIntentSchema.root(
                    properties: [
                        "path": CoreIntentSchema.path,
                        "cursor": CoreIntentSchema.string(maxLength: 512),
                        "limit": CoreIntentSchema.integer(minimum: 1, maximum: 256),
                    ],
                    required: ["path"]
                ),
                output: CoreIntentSchema.root(
                    properties: [
                        "entries": CoreIntentSchema.array(
                            items: CoreIntentSchema.object(
                                properties: [
                                    "name": CoreIntentSchema.string(
                                        minLength: 1,
                                        maxLength: 4_096
                                    ),
                                    "isDirectory": CoreIntentSchema.boolean,
                                ],
                                required: ["name", "isDirectory"]
                            ),
                            maxItems: 256
                        ),
                        "nextCursor": CoreIntentSchema.nullable(
                            CoreIntentSchema.string(maxLength: 512)
                        ),
                    ],
                    required: ["entries", "nextCursor"]
                ),
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(.read),
                errors: [
                    "dev.tenon.core.path-not-found",
                    "dev.tenon.core.filesystem-failed",
                ],
                bindings: [filesystemReadPath],
                admission: .background,
                timeout: .seconds(10),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .filesystemFileRead,
                title: "Read file",
                description: "Returns bounded inline UTF-8 text.",
                input: pathInput,
                output: CoreIntentSchema.root(
                    properties: ["content": CoreIntentSchema.textOutput],
                    required: ["content"]
                ),
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(.read),
                errors: [
                    "dev.tenon.core.path-not-found",
                    "dev.tenon.core.content-not-text",
                    "dev.tenon.core.filesystem-failed",
                ],
                bindings: [filesystemReadPath],
                admission: .background,
                timeout: .seconds(15),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .filesystemPathExists,
                title: "Check path",
                description: "Checks whether a filesystem path exists.",
                input: pathInput,
                output: CoreIntentSchema.root(
                    properties: ["exists": CoreIntentSchema.boolean],
                    required: ["exists"]
                ),
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(.read),
                errors: ["dev.tenon.core.filesystem-failed"],
                bindings: [filesystemReadPath],
                admission: .background,
                timeout: .seconds(5),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .filesystemFileWrite,
                title: "Write file",
                description: "Atomically writes bounded inline UTF-8 content.",
                input: CoreIntentSchema.root(
                    properties: [
                        "path": CoreIntentSchema.path,
                        "content": CoreIntentSchema.textInput,
                    ],
                    required: ["path", "content"]
                ),
                output: emptyOutput,
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(
                    .write,
                    confirmation: .policy
                ),
                errors: [
                    "dev.tenon.core.path-not-found",
                    "dev.tenon.core.filesystem-failed",
                ],
                bindings: [filesystemWritePath],
                admission: .background,
                timeout: .seconds(20),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .filesystemDirectoryCreate,
                title: "Create directory",
                description: "Creates one directory without implicitly creating its ancestors.",
                input: pathInput,
                output: pathOutput,
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(
                    .write,
                    confirmation: .policy
                ),
                errors: [
                    "dev.tenon.core.path-not-found",
                    "dev.tenon.core.path-already-exists",
                    "dev.tenon.core.filesystem-failed",
                ],
                bindings: [filesystemWritePath],
                admission: .background,
                timeout: .seconds(10),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .filesystemFileCreate,
                title: "Create file",
                description: "Creates a new empty file and fails if the destination exists.",
                input: pathInput,
                output: pathOutput,
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(
                    .write,
                    confirmation: .policy
                ),
                errors: [
                    "dev.tenon.core.path-not-found",
                    "dev.tenon.core.path-already-exists",
                    "dev.tenon.core.filesystem-failed",
                ],
                bindings: [filesystemWritePath],
                admission: .background,
                timeout: .seconds(10),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .filesystemPathMove,
                title: "Move path",
                description: "Moves a file or directory without replacing an existing destination.",
                input: CoreIntentSchema.root(
                    properties: [
                        "sourcePath": CoreIntentSchema.path,
                        "destinationPath": CoreIntentSchema.path,
                    ],
                    required: ["sourcePath", "destinationPath"]
                ),
                output: pathOutput,
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(
                    .write,
                    confirmation: .policy
                ),
                errors: [
                    "dev.tenon.core.path-not-found",
                    "dev.tenon.core.path-already-exists",
                    "dev.tenon.core.filesystem-failed",
                ],
                bindings: [filesystemMovePaths],
                admission: .background,
                timeout: .seconds(20),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .filesystemPathTrash,
                title: "Move path to Trash",
                description: "Moves a file or directory to the recoverable system Trash.",
                input: pathInput,
                output: emptyOutput,
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(
                    .destructive,
                    confirmation: .policy
                ),
                errors: [
                    "dev.tenon.core.path-not-found",
                    "dev.tenon.core.filesystem-failed",
                ],
                bindings: [filesystemWritePath],
                admission: .background,
                timeout: .seconds(20),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .fileReveal,
                title: "Reveal file",
                description: "Reveals a path in the system file browser.",
                input: pathInput,
                output: emptyOutput,
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(
                    .write,
                    confirmation: .policy,
                    external: true
                ),
                errors: [
                    "dev.tenon.core.path-not-found",
                    "dev.tenon.core.external-open-failed",
                ],
                bindings: [shellOpenPath],
                admission: .interactive,
                timeout: .seconds(10),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .fileOpen,
                contractClass: .open,
                title: "Open file",
                description: "Opens a path with the trusted default or an explicitly approved provider.",
                input: pathInput,
                output: emptyOutput,
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(
                    .write,
                    confirmation: .policy,
                    external: true
                ),
                errors: [
                    "dev.tenon.core.path-not-found",
                    "dev.tenon.core.external-open-failed",
                ],
                bindings: [shellOpenPath],
                admission: .interactive,
                timeout: .seconds(15),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .clipboardWrite,
                title: "Copy text",
                description: "Writes bounded text to the system clipboard.",
                input: CoreIntentSchema.root(
                    properties: [
                        "text": CoreIntentSchema.inlineText
                    ],
                    required: ["text"]
                ),
                output: emptyOutput,
                audiences: pluginOnly,
                exposure: pluginOnlyExposure,
                effects: try CoreIntentRuleData.effects(
                    .write,
                    external: true
                ),
                errors: ["dev.tenon.core.clipboard-unavailable"],
                admission: .interactive,
                timeout: .seconds(5),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .processExec,
                title: "Execute process",
                description: """
                Runs an unsandboxed local process with the current user's filesystem and \
                network authority. Requires the caller's standing consent; output is \
                bounded.
                """,
                input: CoreIntentSchema.root(
                    properties: [
                        "command": CoreIntentSchema.path,
                        "arguments": CoreIntentSchema.array(
                            items: CoreIntentSchema.string(maxLength: 16_384),
                            maxItems: 1_024
                        ),
                        "workingDirectory": CoreIntentSchema.path,
                        "environment": CoreIntentSchema.array(
                            items: CoreIntentSchema.object(
                                properties: [
                                    "name": CoreIntentSchema.string(
                                        minLength: 1,
                                        maxLength: 1_024
                                    ),
                                    "value": CoreIntentSchema.string(maxLength: 16_384),
                                ],
                                required: ["name", "value"]
                            ),
                            maxItems: 256
                        ),
                        "standardInput": CoreIntentSchema.textInput,
                        "timeoutMs": CoreIntentSchema.integer(
                            minimum: 1,
                            maximum: 60_000
                        ),
                    ],
                    required: ["command", "arguments", "workingDirectory"]
                ),
                output: CoreIntentSchema.root(
                    properties: [
                        "exitCode": CoreIntentSchema.integer(
                            minimum: -2_147_483_648,
                            maximum: 2_147_483_647
                        ),
                        "termination": CoreIntentSchema.string(
                            enumValues: ["exited", "signalled"]
                        ),
                        "standardOutput": CoreIntentSchema.reference(
                            "#/$defs/textOutput"
                        ),
                        "standardError": CoreIntentSchema.reference(
                            "#/$defs/textOutput"
                        ),
                    ],
                    required: [
                        "exitCode",
                        "termination",
                        "standardOutput",
                        "standardError",
                    ],
                    definitions: ["textOutput": CoreIntentSchema.textOutput]
                ),
                audiences: programmatic,
                exposure: programmaticExposure,
                // Consent, not a prompt per call. The `process.exec` capability is the real
                // gate: only a plugin that declared it in its manifest holds the grant, and
                // a second dialog on every invocation just restates that grant. Asking
                // forever is what trains a user to approve without reading, so the mode
                // that repeats costs security instead of buying it. A git panel refreshing
                // its status is the case that proves it.
                effects: try CoreIntentRuleData.effects(
                    .write,
                    confirmation: .policy,
                    external: true
                ),
                errors: [
                    "dev.tenon.core.process-launch-failed",
                    "dev.tenon.core.process-timed-out",
                    "dev.tenon.core.process-output-unavailable",
                ],
                bindings: [processExec],
                admission: .background,
                timeout: .seconds(60),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .terminalWrite,
                title: "Write to terminal",
                description: "Writes bounded text to the terminal identified by invocation scope.",
                input: CoreIntentSchema.root(
                    properties: ["text": CoreIntentSchema.inlineText],
                    required: ["text"]
                ),
                output: emptyOutput,
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(
                    .write,
                    confirmation: .policy,
                    external: true
                ),
                errors: ["dev.tenon.core.terminal-unavailable"],
                bindings: [terminalWrite],
                admission: .interactive,
                timeout: .seconds(10),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .terminalRun,
                title: "Run in terminal",
                description: "Runs a command in the preferred visible terminal for the invocation scope.",
                input: CoreIntentSchema.root(
                    properties: [
                        "command": CoreIntentSchema.string(
                            minLength: 1,
                            maxLength: CoreIntentPayloadPolicy.maximumInlineTextCharacters
                        )
                    ],
                    required: ["command"]
                ),
                output: emptyOutput,
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(
                    .write,
                    confirmation: .policy,
                    external: true
                ),
                errors: ["dev.tenon.core.terminal-unavailable"],
                bindings: [terminalWrite],
                admission: .interactive,
                timeout: .seconds(15),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .terminalOpen,
                title: "Open a terminal in a new tab",
                description: """
                Opens a new terminal tab in the scoped workspace and returns \
                the id of the pane it created. Unlike terminal.run.v1, which \
                reuses a terminal already in scope, this always creates one — \
                for work that needs a pane of its own, such as running an \
                agent against a prompt. An omitted command opens an empty \
                shell. The pane belongs to the workspace once created; the id \
                identifies it for later intents and confers no ownership.
                """,
                input: CoreIntentSchema.root(
                    properties: [
                        "command": CoreIntentSchema.string(
                            maxLength: CoreIntentPayloadPolicy
                                .maximumInlineTextCharacters
                        ),
                        "workingDirectory": CoreIntentSchema.path,
                    ],
                    required: []
                ),
                output: CoreIntentSchema.root(
                    properties: ["paneID": CoreIntentSchema.uuid],
                    required: ["paneID"]
                ),
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(
                    .write,
                    confirmation: .policy,
                    external: true
                ),
                errors: ["dev.tenon.core.terminal-unavailable"],
                bindings: [terminalWrite],
                admission: .interactive,
                timeout: .seconds(15),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .terminalViewportRead,
                title: "Read terminal viewport",
                description: """
                Returns one bounded observation of the visible terminal \
                identified by invocation scope.
                """,
                input: emptyInput,
                output: CoreIntentSchema.root(
                    properties: [
                        "paneID": CoreIntentSchema.uuid,
                        "text": CoreIntentSchema.inlineText,
                        "exited": CoreIntentSchema.boolean,
                        "columns": CoreIntentSchema.nullable(
                            CoreIntentSchema.integer(
                                minimum: 1,
                                maximum: 100_000
                            )
                        ),
                        "rows": CoreIntentSchema.nullable(
                            CoreIntentSchema.integer(
                                minimum: 1,
                                maximum: 100_000
                            )
                        ),
                    ],
                    required: [
                        "paneID",
                        "text",
                        "exited",
                        "columns",
                        "rows",
                    ]
                ),
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(.read),
                errors: ["dev.tenon.core.terminal-unavailable"],
                bindings: [terminalRead],
                admission: .background,
                timeout: .seconds(5),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .terminalScrollbackRead,
                title: "Read terminal scrollback",
                description: """
                Returns one bounded page of the pane's retained scrollback, \
                oldest row first. Omit the cursor to start at the oldest \
                retained row; pass the cursor from the previous page to \
                continue. A null cursor in the result means the page reached \
                the newest row. The cursor addresses rows by position, and the \
                emulator exposes no stable row identity, so a page whose \
                scrollback has changed size since the cursor was issued \
                returns invalidated instead of rows that may have shifted.
                """,
                input: CoreIntentSchema.root(
                    properties: [
                        "maxLines": CoreIntentSchema.integer(
                            minimum: 1,
                            maximum: Int64(
                                CoreIntentPayloadPolicy
                                    .maximumScrollbackPageLines
                            )
                        ),
                        "cursor": CoreIntentSchema.string(
                            maxLength: CoreIntentPayloadPolicy
                                .maximumScrollbackCursorCharacters
                        ),
                    ],
                    required: []
                ),
                output: CoreIntentSchema.root(
                    properties: [
                        "paneID": CoreIntentSchema.uuid,
                        "text": CoreIntentSchema.inlineText,
                        "cursor": CoreIntentSchema.nullable(
                            CoreIntentSchema.string(
                                maxLength: CoreIntentPayloadPolicy
                                    .maximumScrollbackCursorCharacters
                            )
                        ),
                        "invalidated": CoreIntentSchema.boolean,
                        "totalRows": CoreIntentSchema.integer(
                            minimum: 0,
                            maximum: 100_000
                        ),
                    ],
                    required: [
                        "paneID",
                        "text",
                        "cursor",
                        "invalidated",
                        "totalRows",
                    ]
                ),
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(.read),
                errors: ["dev.tenon.core.terminal-unavailable"],
                bindings: [terminalRead],
                admission: .background,
                timeout: .seconds(5),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .terminalWait,
                title: "Wait for terminal condition",
                description: """
                Waits for one bounded terminal condition and returns exactly \
                one result. Continuous output is a separate future resource \
                stream.
                """,
                input: CoreIntentSchema.root(
                    properties: [
                        "condition": CoreIntentSchema.string(
                            enumValues: [
                                "exit",
                                "tui-idle",
                                "command-finished",
                            ]
                        ),
                        "timeoutMs": CoreIntentSchema.integer(
                            minimum: 1,
                            maximum: 55_000
                        ),
                    ],
                    required: ["condition"]
                ),
                output: CoreIntentSchema.root(
                    properties: [
                        "paneID": CoreIntentSchema.uuid,
                        "condition": CoreIntentSchema.string(
                            enumValues: [
                                "exit",
                                "tui-idle",
                                "command-finished",
                            ]
                        ),
                        "met": CoreIntentSchema.boolean,
                    ],
                    required: ["paneID", "condition", "met"]
                ),
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(.read),
                errors: ["dev.tenon.core.terminal-unavailable"],
                bindings: [terminalRead],
                admission: .background,
                timeout: .seconds(60),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .browserSurfaceLoad,
                title: "Load browser surface",
                description: "Loads an HTTP or HTTPS URL in a caller-owned browser surface.",
                input: CoreIntentSchema.root(
                    properties: [
                        "surfaceID": CoreIntentSchema.identifier,
                        "url": CoreIntentSchema.url,
                    ],
                    required: ["surfaceID", "url"]
                ),
                output: emptyOutput,
                audiences: pluginOnly,
                exposure: pluginOnlyExposure,
                effects: try CoreIntentRuleData.effects(
                    .write,
                    confirmation: .policy,
                    external: true
                ),
                errors: [
                    "dev.tenon.core.surface-not-found",
                    "dev.tenon.core.navigation-failed",
                ],
                bindings: [webViewURL],
                admission: .interactive,
                timeout: .seconds(30),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .browserSurfaceBack,
                title: "Go back",
                description: "Navigates a caller-owned browser surface backward.",
                input: CoreIntentSchema.surfaceInput,
                output: emptyOutput,
                audiences: pluginOnly,
                exposure: pluginOnlyExposure,
                effects: try CoreIntentRuleData.effects(
                    .write,
                    external: true
                ),
                errors: [
                    "dev.tenon.core.surface-not-found",
                    "dev.tenon.core.navigation-unavailable",
                ],
                bindings: [webView],
                admission: .interactive,
                timeout: .seconds(10),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .browserSurfaceForward,
                title: "Go forward",
                description: "Navigates a caller-owned browser surface forward.",
                input: CoreIntentSchema.surfaceInput,
                output: emptyOutput,
                audiences: pluginOnly,
                exposure: pluginOnlyExposure,
                effects: try CoreIntentRuleData.effects(
                    .write,
                    external: true
                ),
                errors: [
                    "dev.tenon.core.surface-not-found",
                    "dev.tenon.core.navigation-unavailable",
                ],
                bindings: [webView],
                admission: .interactive,
                timeout: .seconds(10),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .browserSurfaceReload,
                title: "Reload browser surface",
                description: "Reloads a caller-owned browser surface.",
                input: CoreIntentSchema.surfaceInput,
                output: emptyOutput,
                audiences: pluginOnly,
                exposure: pluginOnlyExposure,
                effects: try CoreIntentRuleData.effects(
                    .write,
                    external: true
                ),
                errors: [
                    "dev.tenon.core.surface-not-found",
                    "dev.tenon.core.navigation-failed",
                ],
                bindings: [webView],
                admission: .interactive,
                timeout: .seconds(30),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .uiPick,
                title: "Choose item",
                description: "Asks the user to select one item from a bounded exact list.",
                input: CoreIntentSchema.root(
                    properties: [
                        "items": CoreIntentSchema.array(
                            items: CoreIntentSchema.object(
                                properties: [
                                    "id": CoreIntentSchema.identifier,
                                    "label": CoreIntentSchema.string(
                                        minLength: 1,
                                        maxLength: 512
                                    ),
                                    "detail": CoreIntentSchema.string(maxLength: 2_048),
                                    "icon": CoreIntentSchema.string(maxLength: 256),
                                ],
                                required: ["id", "label"]
                            ),
                            minItems: 1,
                            maxItems: 256
                        ),
                        "placeholder": CoreIntentSchema.string(maxLength: 512),
                    ],
                    required: ["items"]
                ),
                output: CoreIntentSchema.root(
                    properties: [
                        "selectedID": CoreIntentSchema.nullable(
                            CoreIntentSchema.identifier
                        )
                    ],
                    required: ["selectedID"]
                ),
                audiences: pluginOnly,
                exposure: pluginOnlyExposure,
                effects: try CoreIntentRuleData.effects(.write),
                errors: ["dev.tenon.core.user-cancelled"],
                admission: .interactive,
                timeout: .seconds(60),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .uiPrompt,
                title: "Prompt for text",
                description: "Asks the user for bounded text.",
                input: CoreIntentSchema.root(
                    properties: [
                        "title": CoreIntentSchema.string(
                            minLength: 1,
                            maxLength: 512
                        ),
                        "initialValue": CoreIntentSchema.inlineText,
                        "multiline": CoreIntentSchema.boolean,
                    ],
                    required: ["title", "multiline"]
                ),
                output: CoreIntentSchema.root(
                    properties: [
                        "value": CoreIntentSchema.nullable(
                            CoreIntentSchema.inlineText
                        )
                    ],
                    required: ["value"]
                ),
                audiences: pluginOnly,
                exposure: pluginOnlyExposure,
                effects: try CoreIntentRuleData.effects(.write),
                errors: ["dev.tenon.core.user-cancelled"],
                admission: .interactive,
                timeout: .seconds(60),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .uiConfirm,
                title: "Confirm action",
                description: "Asks the user for an explicit yes or no decision.",
                input: CoreIntentSchema.root(
                    properties: [
                        "title": CoreIntentSchema.string(
                            minLength: 1,
                            maxLength: 512
                        ),
                        "destructive": CoreIntentSchema.boolean,
                    ],
                    required: ["title", "destructive"]
                ),
                output: CoreIntentSchema.root(
                    properties: ["confirmed": CoreIntentSchema.boolean],
                    required: ["confirmed"]
                ),
                audiences: pluginOnly,
                exposure: pluginOnlyExposure,
                effects: try CoreIntentRuleData.effects(.write),
                errors: [],
                admission: .interactive,
                timeout: .seconds(60),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .uiToast,
                title: "Show notification",
                description: "Shows a bounded in-app notification.",
                input: CoreIntentSchema.root(
                    properties: [
                        "message": CoreIntentSchema.string(
                            minLength: 1,
                            maxLength: 4_096
                        ),
                        "kind": CoreIntentSchema.string(
                            enumValues: ["info", "success", "warning", "error"]
                        ),
                    ],
                    required: ["message", "kind"]
                ),
                output: emptyOutput,
                audiences: pluginOnly,
                exposure: pluginOnlyExposure,
                effects: try CoreIntentRuleData.effects(.write),
                errors: [],
                admission: .interactive,
                timeout: .seconds(5),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .secretsGet,
                title: "Read secret",
                description: "Reads one value from the caller's isolated secret namespace.",
                input: CoreIntentSchema.secretKeyInput,
                output: CoreIntentSchema.root(
                    properties: [
                        "value": CoreIntentSchema.nullable(
                            CoreIntentSchema.secretValue
                        )
                    ],
                    required: ["value"]
                ),
                audiences: pluginOnly,
                exposure: pluginOnlyExposure,
                effects: try CoreIntentRuleData.effects(.read),
                errors: ["dev.tenon.core.secret-store-failed"],
                bindings: [secrets],
                admission: .background,
                timeout: .seconds(10),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .secretsSet,
                title: "Store secret",
                description: "Stores one value in the caller's isolated secret namespace.",
                input: CoreIntentSchema.root(
                    properties: [
                        "key": CoreIntentSchema.secretKey,
                        "value": CoreIntentSchema.secretValue,
                    ],
                    required: ["key", "value"]
                ),
                output: emptyOutput,
                audiences: pluginOnly,
                exposure: pluginOnlyExposure,
                effects: try CoreIntentRuleData.effects(
                    .write,
                    confirmation: .policy
                ),
                errors: ["dev.tenon.core.secret-store-failed"],
                bindings: [secrets],
                admission: .background,
                timeout: .seconds(10),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .secretsDelete,
                title: "Delete secret",
                description: "Deletes one value from the caller's isolated secret namespace.",
                input: CoreIntentSchema.secretKeyInput,
                output: emptyOutput,
                audiences: pluginOnly,
                exposure: pluginOnlyExposure,
                effects: try CoreIntentRuleData.effects(
                    .destructive,
                    confirmation: .always
                ),
                errors: ["dev.tenon.core.secret-store-failed"],
                bindings: [secrets],
                admission: .background,
                timeout: .seconds(10),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .workspaceState,
                title: "Read workspace state",
                description: "Returns a bounded structural snapshot of workspaces, tabs, and panes.",
                input: CoreIntentSchema.root(
                    properties: [
                        "cursor": CoreIntentSchema.string(maxLength: 512),
                        "limit": CoreIntentSchema.integer(
                            minimum: 1,
                            maximum: 256
                        ),
                    ]
                ),
                output: CoreIntentSchema.workspaceStateOutput,
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(.read),
                errors: [
                    "dev.tenon.core.workspace-unavailable",
                    "dev.tenon.core.cursor-invalidated",
                ],
                admission: .background,
                timeout: .seconds(10),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .workspaceTabCreate,
                title: "Create tab",
                description: "Creates a tab in the workspace identified by invocation scope.",
                input: CoreIntentSchema.root(
                    properties: [
                        "content": CoreIntentSchema.workspaceContentInput
                    ]
                ),
                output: emptyOutput,
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(.write),
                errors: ["dev.tenon.core.workspace-unavailable"],
                bindings: [workspaceControl],
                admission: .interactive,
                timeout: .seconds(10),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .workspacePaneSplit,
                title: "Split pane",
                description: "Splits the pane identified by invocation scope.",
                input: CoreIntentSchema.root(
                    properties: [
                        "axis": CoreIntentSchema.string(
                            enumValues: ["horizontal", "vertical"]
                        )
                    ],
                    required: ["axis"]
                ),
                output: emptyOutput,
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(.write),
                errors: [
                    "dev.tenon.core.workspace-unavailable",
                    "dev.tenon.core.pane-not-found",
                    "dev.tenon.core.layout-unavailable",
                ],
                bindings: [workspaceControl],
                admission: .interactive,
                timeout: .seconds(10),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .workspacePaneFocus,
                title: "Focus pane",
                description: "Focuses the pane identified by invocation scope.",
                input: emptyInput,
                output: emptyOutput,
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(.write),
                errors: ["dev.tenon.core.pane-not-found"],
                bindings: [workspaceControl],
                admission: .interactive,
                timeout: .seconds(5),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .workspacePaneClose,
                title: "Close pane",
                description: "Closes the pane identified by invocation scope.",
                input: emptyInput,
                output: emptyOutput,
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(
                    .destructive,
                    confirmation: .policy
                ),
                errors: [
                    "dev.tenon.core.pane-not-found",
                    "dev.tenon.core.close-refused",
                ],
                bindings: [workspaceControl],
                admission: .interactive,
                timeout: .seconds(10),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .workspacePaneContentSet,
                title: "Set pane content",
                description: "Replaces content in the pane identified by invocation scope.",
                input: CoreIntentSchema.root(
                    properties: [
                        "content": CoreIntentSchema.workspaceContentInput
                    ],
                    required: ["content"]
                ),
                output: emptyOutput,
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(.write),
                errors: [
                    "dev.tenon.core.pane-not-found",
                    "dev.tenon.core.content-unavailable",
                ],
                bindings: [workspaceControl],
                admission: .interactive,
                timeout: .seconds(15),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .workspaceContentOpen,
                title: "Open content",
                description: """
                Opens content in the tab identified by invocation scope, reusing the pane \
                that already shows this kind of content and otherwise splitting a pane. \
                Placement is host policy and never opens a tab.
                """,
                input: CoreIntentSchema.root(
                    properties: [
                        "content": CoreIntentSchema.workspaceContentInput
                    ],
                    required: ["content"]
                ),
                output: emptyOutput,
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(.write),
                errors: [
                    "dev.tenon.core.workspace-unavailable",
                    "dev.tenon.core.workspace-not-found",
                    "dev.tenon.core.pane-not-found",
                    "dev.tenon.core.content-unavailable",
                    "dev.tenon.core.layout-unavailable",
                ],
                bindings: [workspaceControl],
                admission: .interactive,
                timeout: .seconds(15),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .workspaceTabNext,
                title: "Select next tab",
                description: "Selects the next tab in the workspace identified by invocation scope.",
                input: emptyInput,
                output: emptyOutput,
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(.write),
                errors: ["dev.tenon.core.workspace-unavailable"],
                bindings: [workspaceControl],
                admission: .interactive,
                timeout: .seconds(5),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .workspaceTabPrevious,
                title: "Select previous tab",
                description: "Selects the previous tab in the workspace identified by invocation scope.",
                input: emptyInput,
                output: emptyOutput,
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(.write),
                errors: ["dev.tenon.core.workspace-unavailable"],
                bindings: [workspaceControl],
                admission: .interactive,
                timeout: .seconds(5),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .workspacePaneFocusNext,
                title: "Focus next pane",
                description: "Cycles focus within the active tab in invocation scope.",
                input: emptyInput,
                output: emptyOutput,
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(.write),
                errors: ["dev.tenon.core.workspace-unavailable"],
                bindings: [workspaceControl],
                admission: .interactive,
                timeout: .seconds(5),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .workspaceSelect,
                title: "Select workspace",
                description: "Selects the workspace identified by invocation scope.",
                input: emptyInput,
                output: emptyOutput,
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(.write),
                errors: ["dev.tenon.core.workspace-not-found"],
                bindings: [workspaceControl],
                admission: .interactive,
                timeout: .seconds(5),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .networkFetch,
                title: "Fetch network resource",
                description: "Performs one bounded HTTP request to a policy-authorized host.",
                input: CoreIntentSchema.root(
                    properties: [
                        "url": CoreIntentSchema.url,
                        "method": CoreIntentSchema.string(
                            enumValues: [
                                "GET",
                                "HEAD",
                                "POST",
                                "PUT",
                                "PATCH",
                                "DELETE",
                            ]
                        ),
                        "headers": CoreIntentSchema.headers,
                        "body": CoreIntentSchema.textInput,
                        "timeoutMs": CoreIntentSchema.integer(
                            minimum: 1,
                            maximum: 60_000
                        ),
                    ],
                    required: ["url", "method"]
                ),
                output: CoreIntentSchema.root(
                    properties: [
                        "status": CoreIntentSchema.integer(
                            minimum: 100,
                            maximum: 599
                        ),
                        "headers": CoreIntentSchema.headers,
                        "body": CoreIntentSchema.textOutput,
                    ],
                    required: ["status", "headers", "body"]
                ),
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(
                    .write,
                    confirmation: .policy,
                    external: true
                ),
                errors: [
                    "dev.tenon.core.network-failed",
                    "dev.tenon.core.network-response-unavailable",
                ],
                bindings: [networkURL],
                admission: .background,
                timeout: .seconds(60),
                trustedProviderID: trustedProviderID
            ),
        ]
    }
}

private enum CoreIntentRuleData {
    static func exposure(_ audiences: Set<IntentAudience>) -> IntentExposure {
        IntentExposure(
            discoverableBy: audiences,
            invocableBy: audiences
        )
    }

    static func binding(
        capability: String,
        filesystemPaths: [String] = [],
        networkURLs: [String] = []
    ) throws -> IntentCapabilityBinding {
        IntentCapabilityBinding(
            capability: try CapabilityID(capability),
            filesystemPathPointers: try filesystemPaths.map(IntentJSONPointer.init),
            networkURLPointers: try networkURLs.map(IntentJSONPointer.init)
        )
    }

    static func effects(
        _ kind: IntentEffectKind,
        confirmation: IntentConfirmation = .never,
        external: Bool = false
    ) throws -> IntentEffects {
        try IntentEffects(
            kind: kind,
            idempotency: .none,
            retentionMilliseconds: nil,
            confirmation: confirmation,
            external: external
        )
    }

    static func definition(
        _ name: CoreIntentName,
        contractClass: IntentContractClass = .sealed,
        title: String,
        description: String,
        input: IntentValue,
        output: IntentValue,
        audiences: Set<IntentAudience>,
        exposure: IntentExposure,
        effects: IntentEffects,
        errors: [String],
        bindings: [IntentCapabilityBinding] = [],
        admission: IntentAdmissionClass,
        timeout: Duration,
        trustedProviderID: ProviderID
    ) throws -> CoreIntentDefinition {
        let intentID = try name.intentID
        let declaration = IntentContractDeclaration(
            name: intentID,
            contractClass: contractClass,
            owner: .core,
            inputSchema: input,
            outputSchema: output,
            audiences: audiences,
            effects: effects,
            title: title,
            description: description,
            deprecated: false,
            domainErrors: try Set(errors.map(IntentDomainErrorCode.init))
        )
        let dispatchRule = try IntentDispatchRule(
            intentID: intentID,
            capabilityBindings: bindings,
            exposure: exposure,
            trustedDefault: trustedProviderID,
            allowsAutomaticSelection: contractClass == .sealed,
            providerConsent: contractClass == .open ? .nonTrustedProvider : .never,
            admissionClass: admission,
            valueLimits: .default,
            maximumTimeout: timeout
        )
        return CoreIntentDefinition(
            declaration: declaration,
            dispatchRule: dispatchRule
        )
    }
}

private enum CoreIntentSchema {
    static let boolean: IntentValue = .object([
        "type": .string("boolean")
    ])

    static let path = string(minLength: 1, maxLength: 16_384)
    static let identifier = string(minLength: 1, maxLength: 512)
    static let url = string(minLength: 1, maxLength: 16_384, format: "uri")
    static let inlineText = string(
        maxLength: CoreIntentPayloadPolicy.maximumInlineTextCharacters
    )
    static let secretKey = string(minLength: 1, maxLength: 1_024)
    static let secretValue = string(maxLength: 32 * 1_024)

    static let textInput = object(
        properties: [
            "kind": string(constant: "inline"),
            "text": inlineText,
        ],
        required: ["kind", "text"]
    )

    static let textOutput = object(
        properties: [
            "kind": string(constant: "inline"),
            "text": inlineText,
            "byteCount": integer(minimum: 0),
        ],
        required: ["kind", "text", "byteCount"]
    )

    static let headers = array(
        items: object(
            properties: [
                "name": string(minLength: 1, maxLength: 8_192),
                "value": string(maxLength: 16_384),
            ],
            required: ["name", "value"]
        ),
        maxItems: 256
    )

    static let surfaceInput = root(
        properties: ["surfaceID": identifier],
        required: ["surfaceID"]
    )

    static let secretKeyInput = root(
        properties: ["key": secretKey],
        required: ["key"]
    )

    static let workspaceContentInput = oneOf([
        contentKind("terminal"),
        contentKind("changes"),
        contentKind("docs"),
        contentKind("empty"),
        object(
            properties: [
                "kind": string(constant: "file"),
                "path": path,
            ],
            required: ["kind", "path"]
        ),
        object(
            properties: [
                "kind": string(constant: "plugin"),
                "pluginID": string(minLength: 1, maxLength: 253),
                "viewID": identifier,
            ],
            required: ["kind", "pluginID", "viewID"]
        ),
        object(
            properties: [
                "kind": string(constant: "diff"),
                "source": string(constant: "git"),
                "repositoryPath": path,
                "path": path,
                "staged": boolean,
                "untracked": boolean,
                "originalPath": nullable(path),
                "title": string(maxLength: 1_024),
            ],
            required: [
                "kind",
                "source",
                "repositoryPath",
                "path",
                "staged",
                "untracked",
            ]
        ),
        object(
            properties: [
                "kind": string(constant: "diff"),
                "source": string(constant: "inline"),
                "fileName": string(minLength: 1, maxLength: 4_096),
                "oldText": inlineText,
                "newText": inlineText,
                "title": string(maxLength: 1_024),
            ],
            required: [
                "kind",
                "source",
                "fileName",
                "oldText",
                "newText",
            ]
        ),
    ])

    static let workspaceContentSnapshot = oneOf([
        contentKind("terminal"),
        contentKind("changes"),
        contentKind("docs"),
        contentKind("empty"),
        object(
            properties: [
                "kind": string(constant: "file"),
                "path": path,
            ],
            required: ["kind", "path"]
        ),
        object(
            properties: [
                "kind": string(constant: "plugin"),
                "pluginID": string(minLength: 1, maxLength: 253),
                "viewID": identifier,
            ],
            required: ["kind", "pluginID", "viewID"]
        ),
        object(
            properties: [
                "kind": string(constant: "diff"),
                "source": string(constant: "git"),
                "repositoryPath": path,
                "path": path,
                "staged": boolean,
                "untracked": boolean,
                "originalPath": nullable(path),
                "title": string(maxLength: 1_024),
            ],
            required: [
                "kind",
                "source",
                "repositoryPath",
                "path",
                "staged",
                "untracked",
                "originalPath",
                "title",
            ]
        ),
        object(
            properties: [
                "kind": string(constant: "diff"),
                "source": string(constant: "inline"),
                "fileName": string(minLength: 1, maxLength: 4_096),
                "title": string(maxLength: 1_024),
            ],
            required: ["kind", "source", "fileName", "title"]
        ),
    ])

    static let workspaceStateOutput = root(
        properties: [
            "snapshotID": uuid,
            "activeWorkspaceID": uuid,
            "activePaneID": nullable(uuid),
            "nodes": array(
                items: oneOf([
                    object(
                        properties: [
                            "kind": string(constant: "workspace"),
                            "id": uuid,
                            "name": string(
                                minLength: 1,
                                maxLength: 1_024
                            ),
                            "path": path,
                            "selected": boolean,
                            "activeTabID": uuid,
                        ],
                        required: [
                            "kind",
                            "id",
                            "name",
                            "path",
                            "selected",
                            "activeTabID",
                        ]
                    ),
                    object(
                        properties: [
                            "kind": string(constant: "tab"),
                            "id": uuid,
                            "workspaceID": uuid,
                            "selected": boolean,
                            "activePaneID": nullable(uuid),
                        ],
                        required: [
                            "kind",
                            "id",
                            "workspaceID",
                            "selected",
                            "activePaneID",
                        ]
                    ),
                    object(
                        properties: [
                            "kind": string(constant: "pane"),
                            "id": uuid,
                            "tabID": uuid,
                            "content": workspaceContentSnapshot,
                            "frame": object(
                                properties: [
                                    "x": integer(minimum: 0),
                                    "y": integer(minimum: 0),
                                    "width": integer(minimum: 1),
                                    "height": integer(minimum: 1),
                                ],
                                required: [
                                    "x",
                                    "y",
                                    "width",
                                    "height",
                                ]
                            ),
                        ],
                        required: [
                            "kind",
                            "id",
                            "tabID",
                            "content",
                            "frame",
                        ]
                    ),
                ]),
                maxItems: 256
            ),
            "nextCursor": nullable(string(maxLength: 512)),
        ],
        required: [
            "snapshotID",
            "activeWorkspaceID",
            "activePaneID",
            "nodes",
            "nextCursor",
        ]
    )

    static let uuid = string(
        minLength: 36,
        maxLength: 36,
        pattern: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$",
        format: "uuid"
    )

    static func root(
        properties: [String: IntentValue] = [:],
        required: [String] = [],
        definitions: [String: IntentValue] = [:]
    ) -> IntentValue {
        object(
            properties: properties,
            required: required,
            definitions: definitions,
            dialect: true
        )
    }

    static func object(
        properties: [String: IntentValue],
        required: [String] = [],
        definitions: [String: IntentValue] = [:]
    ) -> IntentValue {
        object(
            properties: properties,
            required: required,
            definitions: definitions,
            dialect: false
        )
    }

    static func string(
        minLength: Int? = nil,
        maxLength: Int? = nil,
        enumValues: [String]? = nil,
        constant: String? = nil,
        pattern: String? = nil,
        format: String? = nil
    ) -> IntentValue {
        var fields: [String: IntentValue] = ["type": .string("string")]
        if let minLength {
            fields["minLength"] = .integer(Int64(minLength))
        }
        if let maxLength {
            fields["maxLength"] = .integer(Int64(maxLength))
        }
        if let enumValues {
            fields["enum"] = .array(enumValues.map(IntentValue.string))
        }
        if let constant {
            fields["const"] = .string(constant)
        }
        if let pattern {
            fields["pattern"] = .string(pattern)
        }
        if let format {
            fields["format"] = .string(format)
        }
        return .object(fields)
    }

    static func integer(
        minimum: Int64? = nil,
        maximum: Int64? = nil
    ) -> IntentValue {
        var fields: [String: IntentValue] = ["type": .string("integer")]
        if let minimum {
            fields["minimum"] = .integer(minimum)
        }
        if let maximum {
            fields["maximum"] = .integer(maximum)
        }
        return .object(fields)
    }

    static func array(
        items: IntentValue,
        minItems: Int? = nil,
        maxItems: Int? = nil
    ) -> IntentValue {
        var fields: [String: IntentValue] = [
            "type": .string("array"),
            "items": items,
        ]
        if let minItems {
            fields["minItems"] = .integer(Int64(minItems))
        }
        if let maxItems {
            fields["maxItems"] = .integer(Int64(maxItems))
        }
        return .object(fields)
    }

    static func nullable(_ schema: IntentValue) -> IntentValue {
        oneOf([
            schema,
            .object(["type": .string("null")]),
        ])
    }

    static func reference(_ path: String) -> IntentValue {
        .object(["$ref": .string(path)])
    }

    private static func oneOf(_ schemas: [IntentValue]) -> IntentValue {
        .object(["oneOf": .array(schemas)])
    }

    private static func contentKind(_ kind: String) -> IntentValue {
        object(
            properties: ["kind": string(constant: kind)],
            required: ["kind"]
        )
    }

    private static func object(
        properties: [String: IntentValue],
        required: [String],
        definitions: [String: IntentValue],
        dialect: Bool
    ) -> IntentValue {
        var fields: [String: IntentValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false),
        ]
        if dialect {
            fields["$schema"] = .string(IntentSchemaDialect.draft202012.rawValue)
        }
        if !required.isEmpty {
            fields["required"] = .array(required.map(IntentValue.string))
        }
        if !definitions.isEmpty {
            fields["$defs"] = .object(definitions)
        }
        return .object(fields)
    }
}
