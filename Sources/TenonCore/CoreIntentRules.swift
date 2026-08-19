// @domain: intent-bus
import TenonIntentCore

extension CoreIntentCatalog {
    // MARK: - Catalog installation  @domain: intent-bus
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

    // MARK: - Core intent definitions  @domain: intent-bus
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
        // Same authority, different subject: `shell.open` is "ask for this to be opened by
        // its handler", and the handler for an address is bound by network scope rather
        // than by a filesystem path.
        let shellOpenURL = try CoreIntentRuleData.binding(
            capability: "shell.open",
            networkURLs: ["/url"]
        )
        let clipboardWrite = try CoreIntentRuleData.binding(
            capability: "clipboard.write"
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
                description: """
                Returns one bounded, cursor-addressable page of directory \
                entries. `path` is the listed directory's resolved absolute \
                path. Every entry carries `name` and `isDirectory`. \
                `includeMetadata` defaults to false; setting it true adds \
                `sizeBytes` and `modifiedAt` to every entry, each null when \
                that entry's metadata could not be read. `sizeBytes` is the \
                entry's own size as the filesystem reports it — for a \
                directory that is the directory file itself, not its recursive \
                content — and `modifiedAt` is an ISO-8601 UTC timestamp. \
                Metadata costs one stat per entry, so a caller rendering names \
                alone should leave it off.
                """,
                input: CoreIntentSchema.root(
                    properties: [
                        "path": CoreIntentSchema.path,
                        "cursor": CoreIntentSchema.string(maxLength: 512),
                        "limit": CoreIntentSchema.integer(minimum: 1, maximum: 256),
                        "includeMetadata": CoreIntentSchema.boolean,
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
                                    "sizeBytes": CoreIntentSchema.nullable(
                                        CoreIntentSchema.integer(minimum: 0)
                                    ),
                                    "modifiedAt": CoreIntentSchema.nullable(
                                        CoreIntentSchema.string(
                                            minLength: 20,
                                            maxLength: 32,
                                            format: "date-time"
                                        )
                                    ),
                                ],
                                required: ["name", "isDirectory"]
                            ),
                            maxItems: 256
                        ),
                        "nextCursor": CoreIntentSchema.nullable(
                            CoreIntentSchema.string(maxLength: 512)
                        ),
                        "path": CoreIntentSchema.path,
                    ],
                    required: ["entries", "nextCursor", "path"]
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
                description: """
                Returns one bounded inline UTF-8 page of the file, split only \
                on character boundaries. Omit the cursor to start at the first \
                byte; pass the cursor from the previous page to continue. A \
                null cursor in the result means the page reached the end of \
                the file. The cursor addresses bytes by offset and carries the \
                file identity it was issued against, so a file whose size or \
                modification time changed between pages, or while the page \
                itself was being read, returns invalidated instead of bytes \
                that may have shifted.
                """,
                input: CoreIntentSchema.root(
                    properties: [
                        "path": CoreIntentSchema.path,
                        "cursor": CoreIntentSchema.string(
                            maxLength: CoreIntentPayloadPolicy
                                .maximumFileReadCursorCharacters
                        ),
                    ],
                    required: ["path"]
                ),
                output: CoreIntentSchema.root(
                    properties: [
                        "content": CoreIntentSchema.textOutput,
                        "cursor": CoreIntentSchema.nullable(
                            CoreIntentSchema.string(
                                maxLength: CoreIntentPayloadPolicy
                                    .maximumFileReadCursorCharacters
                            )
                        ),
                        "invalidated": CoreIntentSchema.boolean,
                    ],
                    required: ["content", "cursor", "invalidated"]
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
                description: """
                Atomically replaces the file with bounded inline UTF-8 \
                content. One call with no cursor publishes in a single atomic \
                step. A body larger than one page is staged: pass commit \
                false to open a host-owned staging beside the target and \
                receive a cursor, send each following page with the previous \
                cursor, and let the final page commit (the default) to \
                atomically publish the staged bytes over the target. The \
                target never holds intermediate content; only the committing \
                rename is observable. Staged bytes, concurrent stagings, and \
                staging lifetime are bounded; an abandoned staging is \
                reclaimed and its cursor — like any forged or out-of-sequence \
                cursor — fails closed as invalid input.
                """,
                input: CoreIntentSchema.root(
                    properties: [
                        "path": CoreIntentSchema.path,
                        "content": CoreIntentSchema.textInput,
                        "cursor": CoreIntentSchema.string(
                            maxLength: CoreIntentPayloadPolicy
                                .maximumFileWriteCursorCharacters
                        ),
                        "commit": CoreIntentSchema.boolean,
                    ],
                    required: ["path", "content"]
                ),
                output: CoreIntentSchema.root(
                    properties: [
                        "cursor": CoreIntentSchema.string(
                            maxLength: CoreIntentPayloadPolicy
                                .maximumFileWriteCursorCharacters
                        ),
                    ]
                ),
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
                .urlOpen,
                contractClass: .open,
                title: "Open address",
                description: """
                Opens a web address with the trusted default or an explicitly approved \
                provider. The trusted default hands it to the system; an approved provider \
                may show it inside Tenon instead.
                """,
                input: CoreIntentSchema.root(
                    properties: ["url": CoreIntentSchema.url],
                    required: ["url"]
                ),
                output: emptyOutput,
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(
                    .write,
                    confirmation: .policy,
                    external: true
                ),
                errors: [
                    "dev.tenon.core.invalid-url",
                    "dev.tenon.core.external-open-failed",
                ],
                bindings: [shellOpenURL],
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
                bindings: [clipboardWrite],
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
                .terminalProcessRead,
                title: "Read terminal process identity",
                description: """
                Names the PTY device and the foreground process of the \
                terminal identified by invocation scope. Both are null for a \
                pane whose surface has not materialised and for one whose \
                shell has exited, so an absent answer is stated rather than \
                implied. This is process identity, not resource telemetry: no \
                CPU, memory, or footprint figure crosses this contract.
                """,
                input: emptyInput,
                output: CoreIntentSchema.root(
                    properties: [
                        "paneID": CoreIntentSchema.uuid,
                        "ttyName": CoreIntentSchema.nullable(
                            CoreIntentSchema.string(
                                minLength: 1,
                                maxLength: 1_024
                            )
                        ),
                        "foregroundPID": CoreIntentSchema.nullable(
                            CoreIntentSchema.integer(
                                minimum: 1,
                                maximum: 4_294_967_295
                            )
                        ),
                    ],
                    required: ["paneID", "ttyName", "foregroundPID"]
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
                .workspaceIdentitySet,
                title: "Customise workspace identity",
                description: """
                Changes the name, colour, or icon of the workspace identified by invocation \
                scope. Omitted fields stay unchanged. An empty name restores the folder \
                name; `automatic` restores the derived colour; a symbol replaces any \
                uploaded icon. Custom image data is base64 and is decoded, bounded, and \
                normalized to a small PNG before it enters workspace state.
                """,
                input: CoreIntentSchema.workspaceIdentityInput,
                output: CoreIntentSchema.workspaceIdentityOutput,
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(.write),
                errors: ["dev.tenon.core.workspace-not-found"],
                bindings: [workspaceControl],
                admission: .interactive,
                timeout: .seconds(10),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .workspacePaneOwner,
                title: "Resolve the workspace that owns a pane",
                description: "Returns the workspace and tab that own the named pane.",
                input: CoreIntentSchema.root(
                    properties: ["paneID": CoreIntentSchema.uuid],
                    required: ["paneID"]
                ),
                output: CoreIntentSchema.workspacePaneOwnerOutput,
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(.read),
                errors: ["dev.tenon.core.workspace-unavailable"],
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
                errors: [
                    "dev.tenon.core.workspace-unavailable",
                    "dev.tenon.core.tab-not-found",
                ],
                bindings: [workspaceControl],
                admission: .interactive,
                timeout: .seconds(10),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .workspaceTabFocus,
                title: "Focus tab",
                description: "Focuses the tab identified by invocation scope.",
                input: emptyInput,
                output: emptyOutput,
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(.write),
                errors: ["dev.tenon.core.tab-not-found"],
                bindings: [workspaceControl],
                admission: .interactive,
                timeout: .seconds(5),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .workspaceTabClose,
                title: "Close tab",
                description: """
                Closes the tab identified by invocation scope, with every pane \
                under it. A workspace always keeps one tab, so closing its only \
                tab is refused rather than emptied.
                """,
                input: emptyInput,
                output: emptyOutput,
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(
                    .destructive,
                    confirmation: .policy
                ),
                errors: [
                    "dev.tenon.core.tab-not-found",
                    "dev.tenon.core.close-refused",
                ],
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
                description: """
                Closes the pane identified by invocation scope. If that was a \
                tab's final pane, the empty tab closes when another tab survives; \
                a workspace's required final tab remains as an empty placeholder.
                """,
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
                .workspacePaneTitleSet,
                title: "Set pane title",
                description: """
                Pins a display name to the pane identified by invocation scope, so an \
                agent working there can say on its own tab what it is working on. An \
                empty or whitespace-only title clears the pin and returns the pane to \
                the title its content derives. Titles are collapsed to single spaces \
                and truncated; a caller never chooses how wide a tab is.
                """,
                input: CoreIntentSchema.root(
                    // The kernel refuses an unbounded payload; `PaneTitle` then bounds what
                    // a tab chip can show. An over-long title is truncated rather than
                    // refused, because a 70-character label is a working label.
                    properties: [
                        "title": CoreIntentSchema.string(minLength: 0, maxLength: 4096)
                    ],
                    required: ["title"]
                ),
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
                    "dev.tenon.core.tab-not-found",
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
                errors: [
                    "dev.tenon.core.workspace-unavailable",
                    "dev.tenon.core.tab-not-found",
                ],
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
                errors: [
                    "dev.tenon.core.workspace-unavailable",
                    "dev.tenon.core.tab-not-found",
                ],
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
                errors: [
                    "dev.tenon.core.workspace-unavailable",
                    "dev.tenon.core.tab-not-found",
                ],
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
            try CoreIntentRuleData.definition(
                .agentInventory,
                title: "List the agents this person runs",
                description: """
                Returns the coding agents installed on this machine, each with \
                the options this person habitually passes it, so a caller offers \
                the same choices the Launcher does instead of inventing its own. \
                It carries no executable path and no shell history — only the \
                agent, how to name it to a person, and the options.
                """,
                input: emptyInput,
                output: CoreIntentSchema.root(
                    properties: [
                        "agents": CoreIntentSchema.array(
                            items: CoreIntentSchema.object(
                                properties: [
                                    "id": CoreIntentSchema.agentIdentifier,
                                    "label": CoreIntentSchema.string(
                                        minLength: 1,
                                        maxLength: 128
                                    ),
                                    "arguments": CoreIntentSchema
                                        .agentArguments,
                                    "habit": CoreIntentSchema.nullable(
                                        CoreIntentSchema.string(maxLength: 256)
                                    ),
                                ],
                                required: [
                                    "id",
                                    "label",
                                    "arguments",
                                    "habit",
                                ]
                            ),
                            maxItems: 16
                        )
                    ],
                    required: ["agents"]
                ),
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(.read),
                errors: [],
                bindings: [terminalWrite],
                admission: .background,
                timeout: .seconds(5),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .agentCommand,
                title: "Compose an agent command line",
                description: """
                Returns the command line that starts the named agent the way \
                this person runs it, ready for terminal.open.v1. Give it a \
                prompt to open the agent on that work, or a session to \
                continue: the agent that recorded a session resumes it the \
                provider's own way, and any other agent is handed a prompt \
                naming the session's transcript so it reads the content \
                itself. It starts nothing and writes nothing.
                """,
                input: CoreIntentSchema.root(
                    properties: [
                        "agent": CoreIntentSchema.agentIdentifier,
                        "prompt": CoreIntentSchema.agentPrompt,
                        "session": CoreIntentSchema.object(
                            properties: [
                                "agent": CoreIntentSchema.agentIdentifier,
                                "sessionID": CoreIntentSchema.string(
                                    minLength: 1,
                                    maxLength: 256
                                ),
                                "transcriptPath": CoreIntentSchema.path,
                            ],
                            required: ["agent", "sessionID"]
                        ),
                        "includeUserOptions": CoreIntentSchema.boolean,
                    ],
                    required: ["agent"]
                ),
                output: CoreIntentSchema.root(
                    properties: [
                        "agent": CoreIntentSchema.agentIdentifier,
                        "commandLine": CoreIntentSchema.inlineText,
                        "arguments": CoreIntentSchema.agentArguments,
                        "handoff": CoreIntentSchema.boolean,
                    ],
                    required: [
                        "agent",
                        "commandLine",
                        "arguments",
                        "handoff",
                    ]
                ),
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(.read),
                errors: [
                    "dev.tenon.core.agent-unavailable",
                    "dev.tenon.core.agent-handoff-unresolved",
                ],
                bindings: [terminalWrite],
                admission: .background,
                timeout: .seconds(5),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .agentAsk,
                title: "Ask a bounded agent question",
                description: """
                Records one evidence-backed question against the pane in scope and waits \
                until its exact human or agent recipient chooses an offered typed value, \
                or until the caller-declared deadline expires. The record belongs to the \
                pane rather than the asking process; this intent schedules and types \
                nothing into a terminal.
                """,
                input: CoreIntentSchema.root(
                    properties: [
                        "question": CoreIntentSchema.string(
                            minLength: 1,
                            maxLength: 8 * 1_024
                        ),
                        "choices": CoreIntentSchema.array(
                            items: CoreIntentSchema.object(
                                properties: [
                                    "id": CoreIntentSchema.string(
                                        minLength: 1,
                                        maxLength: 128
                                    ),
                                    "label": CoreIntentSchema.string(
                                        minLength: 1,
                                        maxLength: 256
                                    ),
                                    "value": CoreIntentSchema.agentTypedValue,
                                ],
                                required: ["id", "label", "value"]
                            ),
                            minItems: 1,
                            maxItems: AgentAskStore.maximumChoiceCount
                        ),
                        "evidence": CoreIntentSchema.array(
                            items: CoreIntentSchema.object(
                                properties: [
                                    "label": CoreIntentSchema.string(
                                        minLength: 1,
                                        maxLength: 256
                                    ),
                                    "url": CoreIntentSchema.url,
                                ],
                                required: ["label", "url"]
                            ),
                            minItems: 1,
                            maxItems: AgentAskStore.maximumEvidenceCount
                        ),
                        "recipient": CoreIntentSchema.agentQuestionRecipient,
                        "timeoutMs": CoreIntentSchema.integer(
                            minimum: 1,
                            maximum: Int64(
                                AgentAskStore.maximumTimeoutMilliseconds
                            )
                        ),
                    ],
                    required: [
                        "question",
                        "choices",
                        "evidence",
                        "recipient",
                        "timeoutMs",
                    ]
                ),
                output: CoreIntentSchema.root(
                    properties: [
                        "questionID": CoreIntentSchema.uuid,
                        "status": CoreIntentSchema.string(
                            enumValues: ["answered", "expired"]
                        ),
                        "value": CoreIntentSchema.nullable(
                            CoreIntentSchema.agentTypedValue
                        ),
                    ],
                    required: ["questionID", "status", "value"]
                ),
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(.write),
                errors: [
                    "dev.tenon.core.agent-question-pending",
                    "dev.tenon.core.agent-question-capacity",
                    "dev.tenon.core.agent-question-pane-closed",
                ],
                bindings: [terminalWrite],
                admission: .background,
                timeout: .seconds(60),
                trustedProviderID: trustedProviderID
            ),
        ]
    }
}

// MARK: - Rule data helpers  @domain: intent-bus
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

// MARK: - Schema builders  @domain: intent-bus
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

    /// An agent is named, not enumerated in the schema: the inventory is what says which
    /// names exist today, and a caller that asks for one this machine does not have gets a
    /// typed answer instead of a schema rejection it cannot explain to a person.
    static let agentIdentifier = string(minLength: 1, maxLength: 64)
    static let agentPrompt = string(maxLength: 32 * 1_024)
    static let agentArguments = array(
        items: string(maxLength: 8_192),
        maxItems: 64
    )

    /// JSON Schema treats an integer as both `integer` and `number`, so this union is
    /// `anyOf`, not `oneOf`; otherwise every integer would match twice and be refused.
    static let agentTypedValue = IntentValue.object([
        "anyOf": .array([
            boolean,
            integer(),
            .object(["type": .string("number")]),
            string(maxLength: 8 * 1_024),
        ])
    ])

    static let agentQuestionRecipient = oneOf([
        object(
            properties: ["kind": string(constant: "human")],
            required: ["kind"]
        ),
        object(
            properties: [
                "kind": string(constant: "agent"),
                "principalID": string(minLength: 1, maxLength: 512),
                "sessionRevision": integer(minimum: 0),
            ],
            required: ["kind", "principalID", "sessionRevision"]
        ),
    ])

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

    /// The reference a caller may name a recorded session with. `transcriptPath` passes the
    /// schema on shape alone; whether this host may READ that path is decided after the schema,
    /// against the provider roots with symlinks resolved, and refused as invalid input.
    static let agentSessionContent = object(
        properties: [
            "kind": string(constant: "agentSession"),
            "provider": string(enumValues: ["codex", "claude", "opencode"]),
            "sessionID": string(minLength: 1, maxLength: 256),
            "transcriptPath": path,
            "title": nullable(string(maxLength: 1_024)),
        ],
        required: ["kind", "provider", "sessionID", "transcriptPath"]
    )

    static let workspaceContentInput = oneOf([
        contentKind("terminal"),
        contentKind("changes"),
        contentKind("automation"),
        contentKind("empty"),
        agentSessionContent,
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
        contentKind("automation"),
        contentKind("empty"),
        agentSessionContent,
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

    static let workspaceIdentityInput = root(
        properties: [
            "name": string(maxLength: 4_096),
            "accent": string(
                enumValues: ["automatic"] + AccentColor.allCases.map(\.rawValue)
            ),
            "icon": oneOf([
                object(
                    properties: [
                        "kind": string(constant: "symbol"),
                        "name": string(
                            enumValues: WorkspaceSymbol.allCases.map(\.rawValue)
                        ),
                    ],
                    required: ["kind", "name"]
                ),
                object(
                    properties: [
                        "kind": string(constant: "custom"),
                        "data": string(
                            minLength: 1,
                            maxLength: WorkspaceCustomIcon
                                .maximumImportBase64Characters
                        ),
                    ],
                    required: ["kind", "data"]
                ),
            ]),
        ],
        minProperties: 1
    )

    static let workspaceIdentityOutput = root(
        properties: [
            "workspaceID": uuid,
            "name": string(minLength: 1, maxLength: WorkspaceName.maximumLength),
            "accent": string(
                enumValues: ["automatic"] + AccentColor.allCases.map(\.rawValue)
            ),
            "icon": oneOf([
                object(
                    properties: [
                        "kind": string(constant: "symbol"),
                        "name": string(
                            enumValues: WorkspaceSymbol.allCases.map(\.rawValue)
                        ),
                    ],
                    required: ["kind", "name"]
                ),
                object(
                    properties: [
                        "kind": string(constant: "custom"),
                        "id": uuid,
                        "data": string(
                            minLength: 1,
                            maxLength: WorkspaceCustomIcon
                                .maximumPNGBase64Characters
                        ),
                    ],
                    required: ["kind", "id", "data"]
                ),
            ]),
        ],
        required: ["workspaceID", "name", "accent", "icon"]
    )

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

    /// One edge, resolved for one pane: total, unpaginated, single-valued. Deliberately
    /// carries no workspace name, pane content, or frame — no caller needs them, and every
    /// field added here is a field every future caller has to be handed.
    static let workspacePaneOwnerOutput = root(
        properties: [
            "workspaceID": uuid,
            "workspacePath": path,
            "tabID": uuid,
        ],
        required: ["workspaceID", "workspacePath", "tabID"]
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
        definitions: [String: IntentValue] = [:],
        minProperties: Int? = nil
    ) -> IntentValue {
        object(
            properties: properties,
            required: required,
            definitions: definitions,
            minProperties: minProperties,
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
            minProperties: nil,
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
        minProperties: Int?,
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
        if let minProperties {
            fields["minProperties"] = .integer(Int64(minProperties))
        }
        return .object(fields)
    }
}
