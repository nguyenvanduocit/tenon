import XCTest
@testable import TenonIntentCore

final class ContractCatalogTests: XCTestCase {
    func testRegistersCompiledContractAndPublishesImmutableRevisionedSnapshot() async throws {
        let catalog = ContractCatalog()
        let initial = await catalog.snapshot

        let published = try await catalog.register(
            declaration(
                name: "terminal.run.v1",
                contractClass: .sealed,
                owner: .core
            )
        )

        XCTAssertEqual(initial.revision, 0)
        XCTAssertTrue(initial.contracts.isEmpty)
        XCTAssertEqual(published.revision, 1)
        XCTAssertEqual(
            published.contract(named: try IntentID("terminal.run.v1"))?.owner,
            .core
        )
        let contract = try XCTUnwrap(
            published.contract(named: IntentID("terminal.run.v1"))
        )
        XCTAssertEqual(
            try contract.validateInput(.string("not-an-object")).issues.first?.location,
            .input
        )
        XCTAssertEqual(
            try contract.validateOutput(.string("not-an-object")).issues.first?.location,
            .output
        )
        XCTAssertTrue(initial.contracts.isEmpty, "Published snapshots must remain immutable")
    }

    func testPluginOwnedContractMustMatchItsVerifiedNamespace() async throws {
        let catalog = ContractCatalog()
        let pluginID = PluginID("dev.tenon.git")

        await XCTAssertThrowsErrorAsync(
            try await catalog.register(
                declaration(
                    name: "dev.attacker.git.stage.v1",
                    contractClass: .pluginOwned,
                    owner: .plugin(pluginID)
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ContractCatalogError,
                .pluginNamespaceMismatch(
                    intent: "dev.attacker.git.stage.v1",
                    owner: "dev.tenon.git"
                )
            )
        }
    }

    func testSealedAndOpenContractsAreCoreOwned() async {
        let catalog = ContractCatalog()

        await XCTAssertThrowsErrorAsync(
            try await catalog.register(
                declaration(
                    name: "terminal.run.v1",
                    contractClass: .sealed,
                    owner: .plugin(PluginID("dev.tenon.terminal"))
                )
            )
        ) { error in
            XCTAssertEqual(error as? ContractCatalogError, .coreOwnershipRequired)
        }
    }

    func testAllowsAnnotationAndAdditiveDomainErrorUpdateWithinSameMajor() async throws {
        let catalog = ContractCatalog()
        let original = declaration(
            name: "dev.tenon.git.stage.v1",
            contractClass: .pluginOwned,
            owner: .plugin(PluginID("dev.tenon.git")),
            title: "Stage",
            domainErrors: []
        )
        let updated = declaration(
            name: "dev.tenon.git.stage.v1",
            contractClass: .pluginOwned,
            owner: .plugin(PluginID("dev.tenon.git")),
            title: "Stage files",
            domainErrors: [try IntentDomainErrorCode("dev.tenon.git.index-locked")]
        )

        _ = try await catalog.register(original)
        let snapshot = try await catalog.register(updated)

        let contract = try XCTUnwrap(
            snapshot.contract(named: IntentID("dev.tenon.git.stage.v1"))
        )
        XCTAssertEqual(snapshot.revision, 2)
        XCTAssertEqual(contract.title, "Stage files")
        XCTAssertEqual(
            contract.domainErrors,
            [try IntentDomainErrorCode("dev.tenon.git.index-locked")]
        )
    }

    func testRejectsExecutableSchemaEffectAndDomainErrorRemovalWithinSameMajor() async throws {
        let catalog = ContractCatalog()
        let domainError = try IntentDomainErrorCode("dev.tenon.git.index-locked")
        let original = declaration(
            name: "dev.tenon.git.stage.v1",
            contractClass: .pluginOwned,
            owner: .plugin(PluginID("dev.tenon.git")),
            domainErrors: [domainError]
        )
        _ = try await catalog.register(original)

        let schemaChanged = declaration(
            name: original.name.rawValue,
            contractClass: original.contractClass,
            owner: original.owner,
            inputSchema: objectSchema(
                properties: ["path": .object(["type": .string("string")])]
            ),
            domainErrors: original.domainErrors
        )
        let effectsChanged = declaration(
            name: original.name.rawValue,
            contractClass: original.contractClass,
            owner: original.owner,
            effects: try IntentEffects(
                kind: .destructive,
                idempotency: .none,
                retentionMilliseconds: nil,
                confirmation: .always,
                external: false
            ),
            domainErrors: original.domainErrors
        )
        let errorRemoved = declaration(
            name: original.name.rawValue,
            contractClass: original.contractClass,
            owner: original.owner,
            domainErrors: []
        )

        await assertIncompatible(.inputSchemaChanged, schemaChanged, catalog)
        await assertIncompatible(.effectsChanged, effectsChanged, catalog)
        await assertIncompatible(.domainErrorRemoved, errorRemoved, catalog)
    }

    func testDifferentMajorVersionsCoexistWithoutAliases() async throws {
        let catalog = ContractCatalog()

        _ = try await catalog.register(
            declaration(name: "terminal.run.v1", contractClass: .sealed, owner: .core)
        )
        let snapshot = try await catalog.register(
            declaration(name: "terminal.run.v2", contractClass: .sealed, owner: .core)
        )

        XCTAssertEqual(
            snapshot.allContracts.map(\.name.rawValue),
            ["terminal.run.v1", "terminal.run.v2"]
        )
    }

    func testAllowsSchemaAnnotationChangesWhenExecutableAcceptanceIsStable() async throws {
        let catalog = ContractCatalog()
        let originalSchema: IntentValue = .object([
            "$schema": .string(IntentSchemaDialect.draft202012.rawValue),
            "type": .string("object"),
            "title": .string("Original title"),
            "properties": .object([
                "title": .object([
                    "type": .string("string"),
                    "description": .string("Original description"),
                ])
            ]),
        ])
        let annotatedSchema: IntentValue = .object([
            "$schema": .string(IntentSchemaDialect.draft202012.rawValue),
            "type": .string("object"),
            "title": .string("Revised title"),
            "properties": .object([
                "title": .object([
                    "type": .string("string"),
                    "description": .string("Revised description"),
                ])
            ]),
        ])
        let original = declaration(
            name: "terminal.annotated.v1",
            contractClass: .sealed,
            owner: .core,
            inputSchema: originalSchema
        )
        let updated = declaration(
            name: "terminal.annotated.v1",
            contractClass: .sealed,
            owner: .core,
            inputSchema: annotatedSchema
        )

        _ = try await catalog.register(original)
        let snapshot = try await catalog.register(updated)

        XCTAssertEqual(snapshot.revision, 2)
    }

    private func assertIncompatible(
        _ reason: ContractCompatibilityFailure,
        _ candidate: IntentContractDeclaration,
        _ catalog: ContractCatalog
    ) async {
        await XCTAssertThrowsErrorAsync(try await catalog.register(candidate)) { error in
            XCTAssertEqual(error as? ContractCatalogError, .incompatibleUpdate(reason))
        }
    }
}

private func declaration(
    name: String,
    contractClass: IntentContractClass,
    owner: IntentContractOwner,
    inputSchema: IntentValue = objectSchema(properties: [:]),
    outputSchema: IntentValue = objectSchema(properties: [:]),
    effects: IntentEffects = .pessimistic,
    title: String? = nil,
    domainErrors: Set<IntentDomainErrorCode> = []
) -> IntentContractDeclaration {
    IntentContractDeclaration(
        name: try! IntentID(name),
        contractClass: contractClass,
        owner: owner,
        inputSchema: inputSchema,
        outputSchema: outputSchema,
        audiences: [.plugin, .palette, .cli, .agent],
        effects: effects,
        title: title,
        description: nil,
        deprecated: false,
        domainErrors: domainErrors
    )
}
