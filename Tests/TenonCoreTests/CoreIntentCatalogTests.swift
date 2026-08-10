import Foundation
import TenonIntentCore
@testable import TenonCore
import XCTest

final class CoreIntentCatalogTests: XCTestCase {
    /// The contracts whose handler a person may re-point, and therefore the only ones
    /// built-in UI may reach. See `docs/design-open-handlers.md`.
    private let openContractNames: Set<String> = [
        "file.open.v1",
        "url.open.v1",
    ]

    func testConcurrentInstallCompilesIntoAuthoritativeKernelExactlyOnce() async throws {
        let components = try makeKernel()
        let loader = CoreIntentCatalog(components: components)

        let revisions = try await withThrowingTaskGroup(
            of: UInt64.self,
            returning: [UInt64].self
        ) { group in
            for _ in 0 ..< 32 {
                group.addTask {
                    try await loader.install().contractSnapshot.revision
                }
            }

            var values: [UInt64] = []
            for try await revision in group {
                values.append(revision)
            }
            return values
        }

        let compiled = try await loader.install()
        let compilationCount = await loader.compilationCount
        let authoritativeCatalog = await components.catalog.snapshot
        let authoritativeDispatcher = await components.dispatcher.snapshot()

        XCTAssertEqual(compilationCount, 1)
        XCTAssertEqual(revisions, Array(repeating: 46, count: 32))
        XCTAssertEqual(compiled.definitions.count, 46)
        XCTAssertEqual(compiled.contractSnapshot.contracts.count, 46)
        XCTAssertEqual(compiled.dispatchRules.count, 46)
        XCTAssertEqual(compiled.trustedProviderID.rawValue, "dev.tenon.core")
        XCTAssertEqual(compiled.contractSnapshot, authoritativeCatalog)
        XCTAssertEqual(
            compiled.dispatcherRuleRevision,
            authoritativeDispatcher.ruleRevision
        )
        XCTAssertEqual(compiled.dispatchRules, authoritativeDispatcher.rules)
        XCTAssertEqual(
            Set(compiled.definitions.map(\.declaration.name)),
            Set(compiled.contractSnapshot.contracts.keys)
        )
        XCTAssertEqual(
            Set(compiled.definitions.map(\.declaration.name)),
            Set(compiled.dispatchRules.keys)
        )
    }

    func testInventoryIsCompleteUniqueVersionedAndFreeOfLegacyNames() throws {
        let definitions = try CoreIntentCatalog.definitions()
        let actualNames = definitions.map(\.declaration.name.rawValue)
        let expectedNames = CoreIntentName.allCases.map(\.rawValue)

        XCTAssertEqual(actualNames, expectedNames)
        XCTAssertEqual(Set(actualNames).count, 46)
        XCTAssertEqual(actualNames.count, 46)

        let forbiddenFragments = [
            "tenon.",
            "fs.",
            "web.",
            "net.",
            "readDir",
            "readFile",
            "writeFile",
            "mkdir",
            "createFile",
            "newTab",
            "focusSlot",
            "closeSlot",
            "setContent",
            "nextTab",
            "prevTab",
            "focusNextSlot",
            "switchWorkspace",
        ]
        for name in actualNames {
            // Every contract ends in an explicit major version, and not always `.v1`:
            // a change the same major cannot carry mints the next one instead of
            // mutating a shape callers already bind (`docs/design-intent-bus.md`).
            let version = name.split(separator: ".").last.map(String.init) ?? ""
            XCTAssertTrue(
                version.first == "v" && UInt(version.dropFirst()) != nil,
                name
            )
            for fragment in forbiddenFragments {
                XCTAssertFalse(name.contains(fragment), "\(name) contains \(fragment)")
            }
        }
    }

    /// The directory listing gained a required `path` output, an `includeMetadata` input,
    /// and `sizeBytes`/`modifiedAt` entry fields. Every one of those objects is closed, so
    /// `docs/design-intent-bus.md` ("Add any top-level input/output field to a closed
    /// object — same major? no") makes the change breaking, and a breaking change mints the
    /// next major. This pins the mint: the old id must not resolve, and the new shape must
    /// live behind the new one.
    func testTheDirectoryListingShapeChangeMintedANewMajorInsteadOfMutatingV1() throws {
        XCTAssertNil(CoreIntentName(rawValue: "filesystem.directory.list.v1"))
        XCTAssertEqual(
            CoreIntentName.filesystemDirectoryList.rawValue,
            "filesystem.directory.list.v2"
        )

        let definition = try XCTUnwrap(
            try CoreIntentCatalog.definitions().first {
                $0.declaration.name.rawValue == "filesystem.directory.list.v2"
            }
        )
        let input = try XCTUnwrap(definition.declaration.inputSchema.objectValue)
        let output = try XCTUnwrap(definition.declaration.outputSchema.objectValue)
        XCTAssertNotNil(
            input["properties"]?.objectValue?["includeMetadata"]
        )
        XCTAssertNotNil(output["properties"]?.objectValue?["path"])
        let entry = output["properties"]?.objectValue?["entries"]?
            .objectValue?["items"]?.objectValue?["properties"]?.objectValue
        XCTAssertNotNil(entry?["sizeBytes"])
        XCTAssertNotNil(entry?["modifiedAt"])
    }

    func testEverySchemaHasTheExactTopLevelShapeAndClosedObjectBoundaries() throws {
        let definitions = try CoreIntentCatalog.definitions()
        let expected = expectedSchemaShapes()

        XCTAssertEqual(expected.count, CoreIntentName.allCases.count)
        for definition in definitions {
            let name = try XCTUnwrap(
                CoreIntentName(rawValue: definition.declaration.name.rawValue)
            )
            let shape = try XCTUnwrap(expected[name])

            assertRoot(
                definition.declaration.inputSchema,
                properties: shape.inputProperties,
                required: shape.requiredInput,
                context: "\(name.rawValue) input"
            )
            assertRoot(
                definition.declaration.outputSchema,
                properties: shape.outputProperties,
                required: shape.requiredOutput,
                context: "\(name.rawValue) output"
            )
            assertEveryObjectSchemaIsClosed(
                definition.declaration.inputSchema,
                path: "\(name.rawValue)/input"
            )
            assertEveryObjectSchemaIsClosed(
                definition.declaration.outputSchema,
                path: "\(name.rawValue)/output"
            )
        }
    }

    func testLargeTextContractsAreBoundedInlineOnly() async throws {
        let components = try makeKernel()
        let compiled = try await CoreIntentCatalog(
            components: components
        ).install()
        let fileRead = try contract(.filesystemFileRead, in: compiled)
        let fileWrite = try contract(.filesystemFileWrite, in: compiled)
        let processExec = try contract(.processExec, in: compiled)
        let networkFetch = try contract(.networkFetch, in: compiled)

        let inline: IntentValue = .object([
            "kind": .string("inline"),
            "text": .string("bounded"),
            "byteCount": .integer(7),
        ])
        let unsupportedHandle: IntentValue = .object([
            "kind": .string("resource"),
            "resourceID": .string("resource-42"),
            "byteCount": .integer(262_144),
        ])

        XCTAssertTrue(
            try fileRead.validateOutput(
                .object([
                    "content": inline,
                    "cursor": .null,
                    "invalidated": .bool(false),
                ])
            ).isValid
        )
        XCTAssertFalse(
            try fileRead.validateOutput(
                .object([
                    "content": unsupportedHandle,
                    "cursor": .null,
                    "invalidated": .bool(false),
                ])
            ).isValid
        )
        XCTAssertFalse(
            try fileRead.validateOutput(
                .object([
                    "content": .string("unbounded-shorthand"),
                    "cursor": .null,
                    "invalidated": .bool(false),
                ])
            ).isValid
        )

        let oversizedInline = IntentValue.object([
            "content": .object([
                "kind": .string("inline"),
                "text": .string(
                    String(
                        repeating: "x",
                        count: CoreIntentPayloadPolicy.maximumInlineTextCharacters + 1
                    )
                ),
                "byteCount": .integer(
                    Int64(CoreIntentPayloadPolicy.maximumInlineTextCharacters + 1)
                ),
            ]),
            "cursor": .null,
            "invalidated": .bool(false),
        ])
        XCTAssertFalse(try fileRead.validateOutput(oversizedInline).isValid)

        XCTAssertFalse(
            try fileWrite.validateInput(
                .object([
                    "path": .string("/repo/large.txt"),
                    "content": .object([
                        "kind": .string("resource"),
                        "resourceID": .string("resource-input"),
                    ]),
                ])
            ).isValid
        )
        XCTAssertTrue(
            try fileWrite.validateInput(
                .object([
                    "path": .string("/repo/inline.txt"),
                    "content": .object([
                        "kind": .string("inline"),
                        "text": .string("bounded"),
                    ]),
                ])
            ).isValid
        )

        let stagedWriteCursor = "v1:49152:0B54AD07-1E51-45A2-9E27-2C4E4E2B9C60"
        XCTAssertTrue(
            try fileWrite.validateInput(
                .object([
                    "path": .string("/repo/board.md"),
                    "content": .object([
                        "kind": .string("inline"),
                        "text": .string("staged page"),
                    ]),
                    "cursor": .string(stagedWriteCursor),
                    "commit": .bool(false),
                ])
            ).isValid
        )
        XCTAssertFalse(
            try fileWrite.validateInput(
                .object([
                    "path": .string("/repo/board.md"),
                    "content": .object([
                        "kind": .string("inline"),
                        "text": .string("staged page"),
                    ]),
                    "cursor": .string(
                        String(
                            repeating: "x",
                            count: CoreIntentPayloadPolicy
                                .maximumFileWriteCursorCharacters + 1
                        )
                    ),
                ])
            ).isValid
        )
        XCTAssertFalse(
            try fileWrite.validateInput(
                .object([
                    "path": .string("/repo/board.md"),
                    "content": .object([
                        "kind": .string("inline"),
                        "text": .string("staged page"),
                    ]),
                    "commit": .string("false"),
                ])
            ).isValid
        )
        XCTAssertTrue(try fileWrite.validateOutput(.object([:])).isValid)
        XCTAssertTrue(
            try fileWrite.validateOutput(
                .object(["cursor": .string(stagedWriteCursor)])
            ).isValid
        )
        // Absence, not null, is how a completed write reports "no staging open":
        // the single-page reply stays exactly the pre-paging empty object.
        XCTAssertFalse(
            try fileWrite.validateOutput(.object(["cursor": .null])).isValid
        )

        XCTAssertFalse(
            try processExec.validateOutput(
                .object([
                    "exitCode": .integer(0),
                    "termination": .string("exited"),
                    "standardOutput": unsupportedHandle,
                    "standardError": inline,
                ])
            ).isValid
        )
        XCTAssertFalse(
            try networkFetch.validateOutput(
                .object([
                    "status": .integer(200),
                    "headers": .array([]),
                    "body": unsupportedHandle,
                ])
            ).isValid
        )

        for contract in [fileRead, fileWrite, processExec, networkFetch] {
            let schemas = [
                contract.inputSchema.document,
                contract.outputSchema.document,
            ]
            for schema in schemas {
                let encoded = try schema.canonicalJSONData()
                let text = try XCTUnwrap(
                    String(data: encoded, encoding: .utf8)
                )
                XCTAssertFalse(text.contains(#""resourceID""#))
                XCTAssertFalse(text.contains(#""const":"resource""#))
            }
        }
    }

    func testTerminalReadAndWaitContractsAreFiniteAndBounded()
        async throws
    {
        let compiled = try await CoreIntentCatalog(
            components: makeKernel()
        ).install()
        let viewport = try contract(.terminalViewportRead, in: compiled)
        let wait = try contract(.terminalWait, in: compiled)
        let paneID = UUID()

        XCTAssertTrue(
            try viewport.validateInput(.object([:])).isValid
        )
        XCTAssertTrue(
            try viewport.validateOutput(
                .object([
                    "paneID": .string(paneID.uuidString),
                    "text": .string("prompt"),
                    "exited": .bool(false),
                    "columns": .integer(120),
                    "rows": .integer(40),
                ])
            ).isValid
        )
        XCTAssertTrue(
            try wait.validateInput(
                .object([
                    "condition": .string("tui-idle"),
                    "timeoutMs": .integer(55_000),
                ])
            ).isValid
        )
        XCTAssertFalse(
            try wait.validateInput(
                .object([
                    "condition": .string("tui-idle"),
                    "timeoutMs": .integer(55_001),
                ])
            ).isValid
        )
        XCTAssertFalse(
            try wait.validateInput(
                .object([
                    "condition": .string("continuous-output")
                ])
            ).isValid
        )
        XCTAssertTrue(
            try wait.validateOutput(
                .object([
                    "paneID": .string(paneID.uuidString),
                    "condition": .string("exit"),
                    "met": .bool(false),
                ])
            ).isValid
        )
    }

    /// The pane→workspace edge is a question a plugin asks, not a join it re-derives from
    /// a paginated snapshot. The contract takes exactly the pane and answers with exactly
    /// the owner: total, unpaginated, single-valued.
    func testWorkspacePaneOwnerContractDeclaresPaneInputAndOwnerOutput()
        async throws
    {
        let compiled = try await CoreIntentCatalog(
            components: makeKernel()
        ).install()
        let owner = try contract(.workspacePaneOwner, in: compiled)

        let paneID = UUID()
        let workspaceID = UUID()
        let tabID = UUID()

        XCTAssertTrue(
            try owner.validateInput(
                .object(["paneID": .string(paneID.uuidString)])
            ).isValid
        )
        XCTAssertFalse(try owner.validateInput(.object([:])).isValid)

        XCTAssertTrue(
            try owner.validateOutput(
                .object([
                    "workspaceID": .string(workspaceID.uuidString),
                    "workspacePath": .string("/repo"),
                    "tabID": .string(tabID.uuidString),
                ])
            ).isValid
        )
        XCTAssertFalse(
            try owner.validateOutput(
                .object([
                    "workspaceID": .string(workspaceID.uuidString),
                    "tabID": .string(tabID.uuidString),
                ])
            ).isValid
        )
    }

    func testWorkspaceContractsMatchPagedSnapshotAndTypedDiffShapes()
        async throws
    {
        let compiled = try await CoreIntentCatalog(
            components: makeKernel()
        ).install()
        let state = try contract(.workspaceState, in: compiled)
        let createTab = try contract(.workspaceTabCreate, in: compiled)
        let setContent = try contract(.workspacePaneContentSet, in: compiled)

        let snapshotID = UUID()
        let workspaceID = UUID()
        let tabID = UUID()
        let gitPaneID = UUID()
        let inlinePaneID = UUID()
        XCTAssertTrue(
            try state.validateInput(
                .object([
                    "cursor": .string(
                        "\(snapshotID.uuidString.lowercased()):3"
                    ),
                    "limit": .integer(64),
                ])
            ).isValid
        )
        XCTAssertTrue(
            try state.validateOutput(
                .object([
                    "snapshotID": .string(snapshotID.uuidString),
                    "activeWorkspaceID": .string(workspaceID.uuidString),
                    "activePaneID": .string(gitPaneID.uuidString),
                    "nodes": .array([
                        .object([
                            "kind": .string("workspace"),
                            "id": .string(workspaceID.uuidString),
                            "name": .string("Tenon"),
                            "path": .string("/repo"),
                            "selected": .bool(true),
                            "activeTabID": .string(tabID.uuidString),
                        ]),
                        .object([
                            "kind": .string("tab"),
                            "id": .string(tabID.uuidString),
                            "workspaceID": .string(workspaceID.uuidString),
                            "selected": .bool(true),
                            "activePaneID": .string(gitPaneID.uuidString),
                        ]),
                        .object([
                            "kind": .string("pane"),
                            "id": .string(gitPaneID.uuidString),
                            "tabID": .string(tabID.uuidString),
                            "content": .object([
                                "kind": .string("diff"),
                                "source": .string("git"),
                                "repositoryPath": .string("/repo"),
                                "path": .string("Sources/App.swift"),
                                "staged": .bool(false),
                                "untracked": .bool(false),
                                "originalPath": .null,
                                "title": .string("App.swift"),
                            ]),
                            "frame": .object([
                                "x": .integer(0),
                                "y": .integer(0),
                                "width": .integer(1),
                                "height": .integer(1),
                            ]),
                        ]),
                        .object([
                            "kind": .string("pane"),
                            "id": .string(inlinePaneID.uuidString),
                            "tabID": .string(tabID.uuidString),
                            "content": .object([
                                "kind": .string("diff"),
                                "source": .string("inline"),
                                "fileName": .string("Preview.swift"),
                                "title": .string("Preview"),
                            ]),
                            "frame": .object([
                                "x": .integer(1),
                                "y": .integer(0),
                                "width": .integer(1),
                                "height": .integer(1),
                            ]),
                        ]),
                    ]),
                    "nextCursor": .null,
                ])
            ).isValid
        )
        XCTAssertFalse(
            try state.validateOutput(
                .object([
                    "activeWorkspaceID": .string(workspaceID.uuidString),
                    "activePaneID": .null,
                    "workspaces": .array([]),
                ])
            ).isValid
        )

        XCTAssertTrue(
            try state.validateOutput(
                .object([
                    "snapshotID": .string(snapshotID.uuidString),
                    "activeWorkspaceID": .string(workspaceID.uuidString),
                    "activePaneID": .string(gitPaneID.uuidString),
                    "nodes": .array([
                        .object([
                            "kind": .string("pane"),
                            "id": .string(gitPaneID.uuidString),
                            "tabID": .string(tabID.uuidString),
                            "content": .object([
                                "kind": .string("automation")
                            ]),
                            "frame": .object([
                                "x": .integer(0),
                                "y": .integer(0),
                                "width": .integer(1),
                                "height": .integer(1),
                            ]),
                        ]),
                    ]),
                    "nextCursor": .null,
                ])
            ).isValid
        )

        XCTAssertTrue(
            try createTab.validateInput(
                .object([
                    "content": .object([
                        "kind": .string("automation")
                    ])
                ])
            ).isValid
        )

        XCTAssertTrue(
            try createTab.validateInput(
                .object([
                    "content": .object([
                        "kind": .string("diff"),
                        "source": .string("inline"),
                        "fileName": .string("Preview.swift"),
                        "oldText": .string("before"),
                        "newText": .string("after"),
                        "title": .string("Preview"),
                    ])
                ])
            ).isValid
        )
        XCTAssertFalse(
            try createTab.validateInput(
                .object([
                    "content": .object([
                        "kind": .string("diff"),
                        "source": .string("inline"),
                        "fileName": .string("Preview.swift"),
                        "title": .string("redacted snapshot"),
                    ])
                ])
            ).isValid
        )
        XCTAssertTrue(
            try setContent.validateInput(
                .object([
                    "content": .object([
                        "kind": .string("diff"),
                        "source": .string("git"),
                        "repositoryPath": .string("/repo"),
                        "path": .string("Sources/App.swift"),
                        "staged": .bool(false),
                        "untracked": .bool(false),
                        "originalPath": .null,
                    ])
                ])
            ).isValid
        )
    }

    func testCapabilityInventoryAndArgumentBindingsAreExact() throws {
        let definitions = try CoreIntentCatalog.definitions()
        let expectedCapabilities = expectedCapabilityIDs()

        XCTAssertEqual(expectedCapabilities.count, CoreIntentName.allCases.count)
        for definition in definitions {
            let name = try XCTUnwrap(
                CoreIntentName(rawValue: definition.declaration.name.rawValue)
            )
            XCTAssertEqual(
                definition.dispatchRule.capabilityBindings.map(
                    \.capability.rawValue
                ),
                try XCTUnwrap(expectedCapabilities[name]),
                name.rawValue
            )
        }

        let read = try definition(.filesystemFileRead, in: definitions)
        XCTAssertEqual(
            try read.dispatchRule.capabilityRequirements(
                input: .object(["path": .string("/repo/README.md")])
            ),
            [
                CapabilityRequirement(
                    capability: try CapabilityID("filesystem.read"),
                    filesystemPaths: ["/repo/README.md"]
                )
            ]
        )

        let move = try definition(.filesystemPathMove, in: definitions)
        XCTAssertEqual(
            try move.dispatchRule.capabilityRequirements(
                input: .object([
                    "sourcePath": .string("/repo/old"),
                    "destinationPath": .string("/repo/new"),
                ])
            ),
            [
                CapabilityRequirement(
                    capability: try CapabilityID("filesystem.write"),
                    filesystemPaths: ["/repo/old", "/repo/new"]
                )
            ]
        )

        let process = try definition(.processExec, in: definitions)
        XCTAssertEqual(
            try process.dispatchRule.capabilityRequirements(
                input: .object([
                    "command": .string("/usr/bin/git"),
                    "workingDirectory": .string("/repo"),
                ])
            ),
            [
                CapabilityRequirement(
                    capability: try CapabilityID("process.exec")
                )
            ]
        )
        // Standing consent, not a prompt per call: the `process.exec` capability is the
        // gate, and a dialog on every invocation only trains the user to approve without
        // reading it.
        XCTAssertEqual(process.declaration.effects.confirmation, .policy)
        XCTAssertTrue(
            process.declaration.description?.contains("unsandboxed") == true
        )

        let browserLoad = try definition(.browserSurfaceLoad, in: definitions)
        XCTAssertEqual(
            try browserLoad.dispatchRule.capabilityRequirements(
                input: .object([
                    "surfaceID": .string("docs"),
                    "url": .string("https://Docs.Example.com:443/guide"),
                ])
            ),
            [
                CapabilityRequirement(
                    capability: try CapabilityID("web.view"),
                    networkHosts: ["docs.example.com"]
                )
            ]
        )

        let fetch = try definition(.networkFetch, in: definitions)
        XCTAssertEqual(
            try fetch.dispatchRule.capabilityRequirements(
                input: .object([
                    "url": .string("https://API.Example.com/v1"),
                    "method": .string("GET"),
                ])
            ),
            [
                CapabilityRequirement(
                    capability: try CapabilityID("network"),
                    networkHosts: ["api.example.com"]
                )
            ]
        )
    }

    func testAudienceExposureProviderAndResourcePoliciesAreCoherent() throws {
        let definitions = try CoreIntentCatalog.definitions()
        let trustedProvider = try CoreIntentCatalog.trustedProviderID()

        XCTAssertEqual(
            CoreIntentPayloadPolicy.maximumEncodedBytes,
            IntentValueLimits.default.maxEncodedBytes
        )
        XCTAssertEqual(
            CoreIntentPayloadPolicy.hardMaximumEncodedBytes,
            IntentValueLimits.hardMaximumEncodedBytes
        )

        for definition in definitions {
            let contract = definition.declaration
            let rule = definition.dispatchRule
            XCTAssertEqual(rule.intentID, contract.name)
            XCTAssertEqual(rule.trustedDefault, trustedProvider)
            XCTAssertEqual(rule.valueLimits, .default)
            XCTAssertLessThanOrEqual(
                rule.valueLimits.maxEncodedBytes,
                IntentValueLimits.hardMaximumEncodedBytes
            )
            XCTAssertGreaterThan(rule.maximumTimeout, .zero)
            XCTAssertLessThanOrEqual(rule.maximumTimeout, .seconds(60))
            XCTAssertEqual(rule.exposure.discoverableBy, contract.audiences)
            XCTAssertEqual(rule.exposure.invocableBy, contract.audiences)
            for error in contract.domainErrors {
                XCTAssertTrue(
                    error.rawValue.hasPrefix("dev.tenon.core."),
                    "\(contract.name): \(error)"
                )
            }

            if openContractNames.contains(contract.name.rawValue) {
                XCTAssertEqual(contract.contractClass, .open)
                XCTAssertFalse(rule.allowsAutomaticSelection)
                XCTAssertEqual(rule.providerConsent, .nonTrustedProvider)
            } else {
                XCTAssertEqual(contract.contractClass, .sealed)
                XCTAssertTrue(rule.allowsAutomaticSelection)
                XCTAssertEqual(rule.providerConsent, .never)
            }
        }

        // The exact open inventory. Every entry here is a contract whose handler a person
        // may re-point and which built-in UI may therefore reach, so growing this set is a
        // reviewed decision rather than an edit.
        XCTAssertEqual(
            Set(
                definitions
                    .filter { $0.declaration.contractClass == .open }
                    .map(\.declaration.name.rawValue)
            ),
            openContractNames
        )

        XCTAssertEqual(CoreIntentName.allCases.count, 46)
        XCTAssertEqual(definitions.count, CoreIntentName.allCases.count)
        for name in CoreIntentName.allCases {
            XCTAssertEqual(
                try definition(name, in: definitions).declaration.audiences,
                name.audienceProfile.audiences,
                name.rawValue
            )
        }
        XCTAssertEqual(
            Set(CoreIntentName.allCases.filter {
                $0.audienceProfile == .pluginOnly
            }),
            [
                .clipboardWrite,
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
                .secretsDelete,
            ]
        )

        let expectedExecutionLanes: [
            CoreIntentExecutionLane: Set<CoreIntentName>
        ] = [
            .filesystem: [
                .filesystemDirectoryList,
                .filesystemFileRead,
                .filesystemPathExists,
                .filesystemFileWrite,
                .filesystemDirectoryCreate,
                .filesystemFileCreate,
                .filesystemPathMove,
                .filesystemPathTrash,
            ],
            .system: [.fileReveal, .fileOpen, .urlOpen, .clipboardWrite],
            .process: [.processExec],
            .network: [.networkFetch],
            .workspace: [
                .workspaceState,
                .workspacePaneOwner,
                .workspaceTabCreate,
                .workspaceTabFocus,
                .workspacePaneSplit,
                .workspacePaneFocus,
                .workspacePaneClose,
                .workspacePaneContentSet,
                .workspaceContentOpen,
                .workspaceTabNext,
                .workspaceTabPrevious,
                .workspacePaneFocusNext,
                .workspaceSelect,
            ],
            .terminalImmediate: [
                .terminalWrite,
                .terminalRun,
                .terminalOpen,
                .terminalViewportRead,
                .terminalScrollbackRead,
            ],
            .terminalWait: [.terminalWait],
            .browser: [
                .browserSurfaceLoad,
                .browserSurfaceBack,
                .browserSurfaceForward,
                .browserSurfaceReload,
            ],
            .userPrompt: [.uiPick, .uiPrompt, .uiConfirm],
            .userNotification: [.uiToast],
            .secrets: [.secretsGet, .secretsSet, .secretsDelete],
            .agentImmediate: [.agentInventory, .agentCommand],
        ]
        XCTAssertEqual(
            Set(expectedExecutionLanes.keys),
            Set(CoreIntentExecutionLane.allCases)
        )
        for lane in CoreIntentExecutionLane.allCases {
            XCTAssertEqual(
                Set(CoreIntentName.allCases.filter {
                    $0.executionLane == lane
                }),
                expectedExecutionLanes[lane],
                lane.rawValue
            )
        }

        XCTAssertEqual(
            try definition(.workspacePaneFocus, in: definitions)
                .declaration.inputSchema,
            closedRoot()
        )
        XCTAssertEqual(
            try definition(.workspaceSelect, in: definitions)
                .declaration.inputSchema,
            closedRoot()
        )
    }
}

private extension CoreIntentCatalogTests {
    struct SchemaShape {
        let inputProperties: Set<String>
        let requiredInput: Set<String>
        let outputProperties: Set<String>
        let requiredOutput: Set<String>

        init(
            _ inputProperties: [String],
            required requiredInput: [String],
            output outputProperties: [String],
            requiredOutput: [String]
        ) {
            self.inputProperties = Set(inputProperties)
            self.requiredInput = Set(requiredInput)
            self.outputProperties = Set(outputProperties)
            self.requiredOutput = Set(requiredOutput)
        }
    }

    func expectedSchemaShapes() -> [CoreIntentName: SchemaShape] {
        [
            .filesystemDirectoryList: SchemaShape(
                ["path", "cursor", "limit", "includeMetadata"],
                required: ["path"],
                output: ["entries", "nextCursor", "path"],
                requiredOutput: ["entries", "nextCursor", "path"]
            ),
            .filesystemFileRead: SchemaShape(
                ["path", "cursor"],
                required: ["path"],
                output: ["content", "cursor", "invalidated"],
                requiredOutput: ["content", "cursor", "invalidated"]
            ),
            .filesystemPathExists: SchemaShape(
                ["path"],
                required: ["path"],
                output: ["exists"],
                requiredOutput: ["exists"]
            ),
            .filesystemFileWrite: SchemaShape(
                ["path", "content", "cursor", "commit"],
                required: ["path", "content"],
                output: ["cursor"],
                requiredOutput: []
            ),
            .filesystemDirectoryCreate: SchemaShape(
                ["path"],
                required: ["path"],
                output: ["path"],
                requiredOutput: ["path"]
            ),
            .filesystemFileCreate: SchemaShape(
                ["path"],
                required: ["path"],
                output: ["path"],
                requiredOutput: ["path"]
            ),
            .filesystemPathMove: SchemaShape(
                ["sourcePath", "destinationPath"],
                required: ["sourcePath", "destinationPath"],
                output: ["path"],
                requiredOutput: ["path"]
            ),
            .filesystemPathTrash: SchemaShape(
                ["path"],
                required: ["path"],
                output: [],
                requiredOutput: []
            ),
            .fileReveal: SchemaShape(
                ["path"],
                required: ["path"],
                output: [],
                requiredOutput: []
            ),
            .fileOpen: SchemaShape(
                ["path"],
                required: ["path"],
                output: [],
                requiredOutput: []
            ),
            .urlOpen: SchemaShape(
                ["url"],
                required: ["url"],
                output: [],
                requiredOutput: []
            ),
            .clipboardWrite: SchemaShape(
                ["text"],
                required: ["text"],
                output: [],
                requiredOutput: []
            ),
            .processExec: SchemaShape(
                [
                    "command",
                    "arguments",
                    "workingDirectory",
                    "environment",
                    "standardInput",
                    "timeoutMs",
                ],
                required: ["command", "arguments", "workingDirectory"],
                output: [
                    "exitCode",
                    "termination",
                    "standardOutput",
                    "standardError",
                ],
                requiredOutput: [
                    "exitCode",
                    "termination",
                    "standardOutput",
                    "standardError",
                ]
            ),
            .terminalWrite: SchemaShape(
                ["text"],
                required: ["text"],
                output: [],
                requiredOutput: []
            ),
            .terminalRun: SchemaShape(
                ["command"],
                required: ["command"],
                output: [],
                requiredOutput: []
            ),
            .terminalOpen: SchemaShape(
                ["command", "workingDirectory"],
                required: [],
                output: ["paneID"],
                requiredOutput: ["paneID"]
            ),
            .terminalViewportRead: SchemaShape(
                [],
                required: [],
                output: [
                    "paneID",
                    "text",
                    "exited",
                    "columns",
                    "rows",
                ],
                requiredOutput: [
                    "paneID",
                    "text",
                    "exited",
                    "columns",
                    "rows",
                ]
            ),
            .terminalScrollbackRead: SchemaShape(
                ["maxLines", "cursor"],
                required: [],
                output: [
                    "paneID",
                    "text",
                    "cursor",
                    "invalidated",
                    "totalRows",
                ],
                requiredOutput: [
                    "paneID",
                    "text",
                    "cursor",
                    "invalidated",
                    "totalRows",
                ]
            ),
            .terminalWait: SchemaShape(
                ["condition", "timeoutMs"],
                required: ["condition"],
                output: ["paneID", "condition", "met"],
                requiredOutput: ["paneID", "condition", "met"]
            ),
            .browserSurfaceLoad: SchemaShape(
                ["surfaceID", "url"],
                required: ["surfaceID", "url"],
                output: [],
                requiredOutput: []
            ),
            .browserSurfaceBack: surfaceShape(),
            .browserSurfaceForward: surfaceShape(),
            .browserSurfaceReload: surfaceShape(),
            .uiPick: SchemaShape(
                ["items", "placeholder"],
                required: ["items"],
                output: ["selectedID"],
                requiredOutput: ["selectedID"]
            ),
            .uiPrompt: SchemaShape(
                ["title", "initialValue", "multiline"],
                required: ["title", "multiline"],
                output: ["value"],
                requiredOutput: ["value"]
            ),
            .uiConfirm: SchemaShape(
                ["title", "destructive"],
                required: ["title", "destructive"],
                output: ["confirmed"],
                requiredOutput: ["confirmed"]
            ),
            .uiToast: SchemaShape(
                ["message", "kind"],
                required: ["message", "kind"],
                output: [],
                requiredOutput: []
            ),
            .secretsGet: SchemaShape(
                ["key"],
                required: ["key"],
                output: ["value"],
                requiredOutput: ["value"]
            ),
            .secretsSet: SchemaShape(
                ["key", "value"],
                required: ["key", "value"],
                output: [],
                requiredOutput: []
            ),
            .secretsDelete: SchemaShape(
                ["key"],
                required: ["key"],
                output: [],
                requiredOutput: []
            ),
            .workspaceState: SchemaShape(
                ["cursor", "limit"],
                required: [],
                output: [
                    "snapshotID",
                    "activeWorkspaceID",
                    "activePaneID",
                    "nodes",
                    "nextCursor",
                ],
                requiredOutput: [
                    "snapshotID",
                    "activeWorkspaceID",
                    "activePaneID",
                    "nodes",
                    "nextCursor",
                ]
            ),
            .workspacePaneOwner: SchemaShape(
                ["paneID"],
                required: ["paneID"],
                output: ["workspaceID", "workspacePath", "tabID"],
                requiredOutput: ["workspaceID", "workspacePath", "tabID"]
            ),
            .workspaceTabCreate: SchemaShape(
                ["content"],
                required: [],
                output: [],
                requiredOutput: []
            ),
            .workspaceTabFocus: emptyShape(),
            .workspacePaneSplit: SchemaShape(
                ["axis"],
                required: ["axis"],
                output: [],
                requiredOutput: []
            ),
            .workspacePaneFocus: emptyShape(),
            .workspacePaneClose: emptyShape(),
            .workspacePaneContentSet: SchemaShape(
                ["content"],
                required: ["content"],
                output: [],
                requiredOutput: []
            ),
            .workspaceContentOpen: SchemaShape(
                ["content"],
                required: ["content"],
                output: [],
                requiredOutput: []
            ),
            .workspaceTabNext: emptyShape(),
            .workspaceTabPrevious: emptyShape(),
            .workspacePaneFocusNext: emptyShape(),
            .workspaceSelect: emptyShape(),
            .networkFetch: SchemaShape(
                ["url", "method", "headers", "body", "timeoutMs"],
                required: ["url", "method"],
                output: ["status", "headers", "body"],
                requiredOutput: ["status", "headers", "body"]
            ),
            .agentInventory: SchemaShape(
                [],
                required: [],
                output: ["agents"],
                requiredOutput: ["agents"]
            ),
            .agentCommand: SchemaShape(
                ["agent", "prompt", "session", "includeUserOptions"],
                required: ["agent"],
                output: ["agent", "commandLine", "arguments", "handoff"],
                requiredOutput: [
                    "agent",
                    "commandLine",
                    "arguments",
                    "handoff",
                ]
            ),
        ]
    }

    func makeKernel() throws -> IntentKernelComponents {
        try IntentKernelComponents(
            persistence: IntentSQLiteIdempotencyPersistence.inMemory()
        )
    }

    func expectedCapabilityIDs() -> [CoreIntentName: [String]] {
        [
            .filesystemDirectoryList: ["filesystem.read"],
            .filesystemFileRead: ["filesystem.read"],
            .filesystemPathExists: ["filesystem.read"],
            .filesystemFileWrite: ["filesystem.write"],
            .filesystemDirectoryCreate: ["filesystem.write"],
            .filesystemFileCreate: ["filesystem.write"],
            .filesystemPathMove: ["filesystem.write"],
            .filesystemPathTrash: ["filesystem.write"],
            .fileReveal: ["shell.open"],
            .fileOpen: ["shell.open"],
            .urlOpen: ["shell.open"],
            .clipboardWrite: [],
            .processExec: ["process.exec"],
            .terminalWrite: ["terminal.write"],
            .terminalRun: ["terminal.write"],
            .terminalOpen: ["terminal.write"],
            .terminalViewportRead: ["terminal.read"],
            .terminalScrollbackRead: ["terminal.read"],
            .terminalWait: ["terminal.read"],
            .browserSurfaceLoad: ["web.view"],
            .browserSurfaceBack: ["web.view"],
            .browserSurfaceForward: ["web.view"],
            .browserSurfaceReload: ["web.view"],
            .uiPick: [],
            .uiPrompt: [],
            .uiConfirm: [],
            .uiToast: [],
            .secretsGet: ["secrets"],
            .secretsSet: ["secrets"],
            .secretsDelete: ["secrets"],
            .workspaceState: [],
            .workspacePaneOwner: [],
            .workspaceTabCreate: ["workspace.control"],
            .workspaceTabFocus: ["workspace.control"],
            .workspacePaneSplit: ["workspace.control"],
            .workspacePaneFocus: ["workspace.control"],
            .workspacePaneClose: ["workspace.control"],
            .workspacePaneContentSet: ["workspace.control"],
            .workspaceContentOpen: ["workspace.control"],
            .workspaceTabNext: ["workspace.control"],
            .workspaceTabPrevious: ["workspace.control"],
            .workspacePaneFocusNext: ["workspace.control"],
            .workspaceSelect: ["workspace.control"],
            .networkFetch: ["network"],
            // Knowing which agent a person runs, and composing the line that would run it,
            // grant nothing a caller that may already write to a terminal did not have.
            .agentInventory: ["terminal.write"],
            .agentCommand: ["terminal.write"],
        ]
    }

    func surfaceShape() -> SchemaShape {
        SchemaShape(
            ["surfaceID"],
            required: ["surfaceID"],
            output: [],
            requiredOutput: []
        )
    }

    func emptyShape() -> SchemaShape {
        SchemaShape([], required: [], output: [], requiredOutput: [])
    }

    func assertRoot(
        _ schema: IntentValue,
        properties expectedProperties: Set<String>,
        required expectedRequired: Set<String>,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .object(fields) = schema else {
            return XCTFail("\(context) is not an object", file: file, line: line)
        }
        XCTAssertEqual(
            fields["$schema"],
            .string(IntentSchemaDialect.draft202012.rawValue),
            context,
            file: file,
            line: line
        )
        XCTAssertEqual(
            fields["type"],
            .string("object"),
            context,
            file: file,
            line: line
        )
        XCTAssertEqual(
            fields["additionalProperties"],
            .bool(false),
            context,
            file: file,
            line: line
        )

        guard case let .object(properties)? = fields["properties"] else {
            return XCTFail(
                "\(context) has no properties map",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(
            Set(properties.keys),
            expectedProperties,
            context,
            file: file,
            line: line
        )

        let required: Set<String>
        if case let .array(values)? = fields["required"] {
            required = Set(values.compactMap { value in
                guard case let .string(name) = value else {
                    return nil
                }
                return name
            })
        } else {
            required = []
        }
        XCTAssertEqual(
            required,
            expectedRequired,
            context,
            file: file,
            line: line
        )
    }

    func assertEveryObjectSchemaIsClosed(
        _ value: IntentValue,
        path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch value {
        case let .object(fields):
            if fields["type"] == .string("object") {
                XCTAssertEqual(
                    fields["additionalProperties"],
                    .bool(false),
                    "\(path) must be closed",
                    file: file,
                    line: line
                )
                guard case .object? = fields["properties"] else {
                    return XCTFail(
                        "\(path) must declare properties",
                        file: file,
                        line: line
                    )
                }
            }
            for (name, child) in fields {
                assertEveryObjectSchemaIsClosed(
                    child,
                    path: "\(path)/\(name)",
                    file: file,
                    line: line
                )
            }
        case let .array(values):
            for (index, child) in values.enumerated() {
                assertEveryObjectSchemaIsClosed(
                    child,
                    path: "\(path)/\(index)",
                    file: file,
                    line: line
                )
            }
        case .null, .bool, .integer, .number, .string:
            break
        }
    }

    func definition(
        _ name: CoreIntentName,
        in definitions: [CoreIntentDefinition]
    ) throws -> CoreIntentDefinition {
        try XCTUnwrap(
            definitions.first {
                $0.declaration.name.rawValue == name.rawValue
            }
        )
    }

    func contract(
        _ name: CoreIntentName,
        in compiled: CompiledCoreIntentCatalog
    ) throws -> IntentContract {
        try XCTUnwrap(
            compiled.contractSnapshot.contract(
                named: try name.intentID
            )
        )
    }

    func closedRoot() -> IntentValue {
        .object([
            "$schema": .string(IntentSchemaDialect.draft202012.rawValue),
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ])
    }
}
