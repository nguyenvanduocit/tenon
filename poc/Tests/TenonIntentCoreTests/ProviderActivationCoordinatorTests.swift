import XCTest
@testable import TenonIntentCore

final class ProviderActivationCoordinatorTests: XCTestCase {
    func testCoreStagesSealedAndOpenCanonicalContracts() async throws {
        let sealed = try IntentID("core.fs.read-file.v1")
        let open = try IntentID("file.open.v1")
        let catalog = ContractCatalog()
        _ = try await catalog.register(
            activationContract(name: sealed, contractClass: .sealed, owner: .core)
        )
        _ = try await catalog.register(
            activationContract(name: open, contractClass: .open, owner: .core)
        )
        let coordinator = ProviderActivationCoordinator(
            catalog: catalog,
            registry: ProviderRegistry()
        )
        let providerID = try ProviderID("dev.tenon.core")
        let candidate = try activationCandidate(
            providerID: providerID,
            owner: .core,
            intentIDs: [sealed, open]
        )

        let nextGeneration = try await coordinator.nextGeneration(for: providerID)
        XCTAssertEqual(nextGeneration, 1)
        try await coordinator.stageCore(candidate)
        try await coordinator.activate(providerID: providerID, generation: 1)

        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.generations.count, 1)
        XCTAssertEqual(snapshot.generations[0].lifecycle, .active)
        XCTAssertEqual(
            snapshot.generations[0].intentIDs.map(\.rawValue).sorted(),
            [sealed.rawValue, open.rawValue].sorted()
        )
    }

    func testOwningPluginStagesItsExactManifestContract() async throws {
        let pluginID = PluginID("dev.tenon.git")
        let installationID = try XCTUnwrap(
            UUID(uuidString: "E2BFA66E-0957-4F90-A283-B6DC8FD2887A")
        )
        let intentID = try IntentID("dev.tenon.git.stage.v1")
        let catalog = ContractCatalog()
        _ = try await catalog.register(
            activationContract(
                name: intentID,
                contractClass: .pluginOwned,
                owner: .plugin(pluginID)
            )
        )
        let coordinator = ProviderActivationCoordinator(
            catalog: catalog,
            registry: ProviderRegistry()
        )
        let owner = IntentProviderOwner.plugin(
            id: pluginID,
            installationID: installationID
        )
        let candidate = try activationCandidate(
            providerID: ProviderID(pluginID.rawValue),
            owner: owner,
            intentIDs: [intentID]
        )

        try await coordinator.stagePlugin(
            candidate,
            authorization: PluginProviderActivationAuthorization(
                pluginID: pluginID,
                installationID: installationID,
                manifestProvidedIntentIDs: [intentID]
            )
        )

        let snapshot = await coordinator.snapshot()
        let generation = try XCTUnwrap(snapshot.generations.first)
        XCTAssertEqual(generation.owner, owner)
        XCTAssertEqual(generation.lifecycle, .staging)
        XCTAssertEqual(generation.exportedIntentIDs, [intentID])
    }

    func testPluginStagesHostApprovedOpenAlternative() async throws {
        let pluginID = PluginID("dev.tenon.editor")
        let installationID = UUID()
        let intentID = try IntentID("file.open.v1")
        let catalog = ContractCatalog()
        _ = try await catalog.register(
            activationContract(name: intentID, contractClass: .open, owner: .core)
        )
        let coordinator = ProviderActivationCoordinator(
            catalog: catalog,
            registry: ProviderRegistry()
        )
        let owner = IntentProviderOwner.plugin(
            id: pluginID,
            installationID: installationID
        )

        try await coordinator.stagePlugin(
            activationCandidate(
                providerID: ProviderID(pluginID.rawValue),
                owner: owner,
                intentIDs: [intentID]
            ),
            authorization: PluginProviderActivationAuthorization(
                pluginID: pluginID,
                installationID: installationID,
                manifestProvidedIntentIDs: [intentID],
                approvedOpenIntentIDs: [intentID]
            )
        )

        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.generations.count, 1)
    }

    func testRejectsCandidateWhoseOwnerDoesNotMatchInstallationAuthorization() async throws {
        let pluginID = PluginID("dev.tenon.git")
        let authorizedInstallationID = UUID()
        let attackerInstallationID = UUID()
        let intentID = try IntentID("dev.tenon.git.stage.v1")
        let catalog = ContractCatalog()
        _ = try await catalog.register(
            activationContract(
                name: intentID,
                contractClass: .pluginOwned,
                owner: .plugin(pluginID)
            )
        )
        let coordinator = ProviderActivationCoordinator(
            catalog: catalog,
            registry: ProviderRegistry()
        )
        let attacker = IntentProviderOwner.plugin(
            id: pluginID,
            installationID: attackerInstallationID
        )
        let providerID = try ProviderID(pluginID.rawValue)

        await assertActivationRejected(
            .providerOwnerMismatch(
                providerID: providerID,
                expected: .plugin(
                    id: pluginID,
                    installationID: authorizedInstallationID
                ),
                actual: attacker
            ),
            coordinator: coordinator
        ) {
            try await coordinator.stagePlugin(
                activationCandidate(
                    providerID: providerID,
                    owner: attacker,
                    intentIDs: [intentID]
                ),
                authorization: PluginProviderActivationAuthorization(
                    pluginID: pluginID,
                    installationID: authorizedInstallationID,
                    manifestProvidedIntentIDs: [intentID]
                )
            )
        }
    }

    func testRejectsPluginProviderIdentityDifferentFromImmutablePluginID() async throws {
        let pluginID = PluginID("dev.tenon.git")
        let installationID = UUID()
        let intentID = try IntentID("dev.tenon.git.stage.v1")
        let catalog = ContractCatalog()
        _ = try await catalog.register(
            activationContract(
                name: intentID,
                contractClass: .pluginOwned,
                owner: .plugin(pluginID)
            )
        )
        let coordinator = ProviderActivationCoordinator(
            catalog: catalog,
            registry: ProviderRegistry()
        )
        let owner = IntentProviderOwner.plugin(
            id: pluginID,
            installationID: installationID
        )
        let attackerProviderID = try ProviderID("example.attacker")

        await assertActivationRejected(
            .pluginProviderIdentityMismatch(
                pluginID: pluginID,
                providerID: attackerProviderID
            ),
            coordinator: coordinator
        ) {
            try await coordinator.stagePlugin(
                activationCandidate(
                    providerID: attackerProviderID,
                    owner: owner,
                    intentIDs: [intentID]
                ),
                authorization: PluginProviderActivationAuthorization(
                    pluginID: pluginID,
                    installationID: installationID,
                    manifestProvidedIntentIDs: [intentID]
                )
            )
        }
    }

    func testRejectsBindingsThatDifferFromManifestProvidedSet() async throws {
        let pluginID = PluginID("dev.tenon.git")
        let installationID = UUID()
        let declared = try IntentID("dev.tenon.git.stage.v1")
        let unexpected = try IntentID("dev.tenon.git.commit.v1")
        let coordinator = ProviderActivationCoordinator(
            catalog: ContractCatalog(),
            registry: ProviderRegistry()
        )
        let owner = IntentProviderOwner.plugin(
            id: pluginID,
            installationID: installationID
        )

        await assertActivationRejected(
            .manifestBindingsMismatch(
                missing: [declared],
                unexpected: [unexpected]
            ),
            coordinator: coordinator
        ) {
            try await coordinator.stagePlugin(
                activationCandidate(
                    providerID: ProviderID(pluginID.rawValue),
                    owner: owner,
                    intentIDs: [unexpected]
                ),
                authorization: PluginProviderActivationAuthorization(
                    pluginID: pluginID,
                    installationID: installationID,
                    manifestProvidedIntentIDs: [declared]
                )
            )
        }
    }

    func testRejectsUnexportedPluginBinding() async throws {
        let pluginID = PluginID("dev.tenon.git")
        let installationID = UUID()
        let intentID = try IntentID("dev.tenon.git.stage.v1")
        let catalog = ContractCatalog()
        _ = try await catalog.register(
            activationContract(
                name: intentID,
                contractClass: .pluginOwned,
                owner: .plugin(pluginID)
            )
        )
        let coordinator = ProviderActivationCoordinator(
            catalog: catalog,
            registry: ProviderRegistry()
        )
        let owner = IntentProviderOwner.plugin(
            id: pluginID,
            installationID: installationID
        )

        await assertActivationRejected(
            .unexportedPluginBinding(intentID),
            coordinator: coordinator
        ) {
            try await coordinator.stagePlugin(
                activationCandidate(
                    providerID: ProviderID(pluginID.rawValue),
                    owner: owner,
                    intentIDs: [intentID],
                    isExported: false
                ),
                authorization: PluginProviderActivationAuthorization(
                    pluginID: pluginID,
                    installationID: installationID,
                    manifestProvidedIntentIDs: [intentID]
                )
            )
        }
    }

    func testRejectsUnknownContractBeforeRegistryMutation() async throws {
        let pluginID = PluginID("dev.tenon.git")
        let installationID = UUID()
        let unknown = try IntentID("dev.tenon.git.unknown.v1")
        let coordinator = ProviderActivationCoordinator(
            catalog: ContractCatalog(),
            registry: ProviderRegistry()
        )
        let owner = IntentProviderOwner.plugin(
            id: pluginID,
            installationID: installationID
        )

        await assertActivationRejected(
            .unknownContract(unknown),
            coordinator: coordinator
        ) {
            try await coordinator.stagePlugin(
                activationCandidate(
                    providerID: ProviderID(pluginID.rawValue),
                    owner: owner,
                    intentIDs: [unknown]
                ),
                authorization: PluginProviderActivationAuthorization(
                    pluginID: pluginID,
                    installationID: installationID,
                    manifestProvidedIntentIDs: [unknown]
                )
            )
        }
    }

    func testRejectsPluginBindingToSealedCoreContract() async throws {
        let pluginID = PluginID("example.attacker")
        let installationID = UUID()
        let sealed = try IntentID("core.fs.read-file.v1")
        let catalog = ContractCatalog()
        _ = try await catalog.register(
            activationContract(name: sealed, contractClass: .sealed, owner: .core)
        )
        let coordinator = ProviderActivationCoordinator(
            catalog: catalog,
            registry: ProviderRegistry()
        )
        let owner = IntentProviderOwner.plugin(
            id: pluginID,
            installationID: installationID
        )

        await assertActivationRejected(
            .sealedContractRequiresCore(sealed),
            coordinator: coordinator
        ) {
            try await coordinator.stagePlugin(
                activationCandidate(
                    providerID: ProviderID(pluginID.rawValue),
                    owner: owner,
                    intentIDs: [sealed]
                ),
                authorization: PluginProviderActivationAuthorization(
                    pluginID: pluginID,
                    installationID: installationID,
                    manifestProvidedIntentIDs: [sealed]
                )
            )
        }
    }

    func testRejectsPluginBindingToAnotherPluginsContract() async throws {
        let ownerPluginID = PluginID("dev.tenon.git")
        let attackerPluginID = PluginID("example.attacker")
        let installationID = UUID()
        let intentID = try IntentID("dev.tenon.git.stage.v1")
        let catalog = ContractCatalog()
        _ = try await catalog.register(
            activationContract(
                name: intentID,
                contractClass: .pluginOwned,
                owner: .plugin(ownerPluginID)
            )
        )
        let coordinator = ProviderActivationCoordinator(
            catalog: catalog,
            registry: ProviderRegistry()
        )
        let attacker = IntentProviderOwner.plugin(
            id: attackerPluginID,
            installationID: installationID
        )

        await assertActivationRejected(
            .contractOwnerMismatch(
                intentID: intentID,
                expected: .plugin(attackerPluginID),
                actual: .plugin(ownerPluginID)
            ),
            coordinator: coordinator
        ) {
            try await coordinator.stagePlugin(
                activationCandidate(
                    providerID: ProviderID(attackerPluginID.rawValue),
                    owner: attacker,
                    intentIDs: [intentID]
                ),
                authorization: PluginProviderActivationAuthorization(
                    pluginID: attackerPluginID,
                    installationID: installationID,
                    manifestProvidedIntentIDs: [intentID]
                )
            )
        }
    }

    func testRejectsOpenPluginAlternativeWithoutHostApproval() async throws {
        let pluginID = PluginID("dev.tenon.editor")
        let installationID = UUID()
        let intentID = try IntentID("file.open.v1")
        let catalog = ContractCatalog()
        _ = try await catalog.register(
            activationContract(name: intentID, contractClass: .open, owner: .core)
        )
        let coordinator = ProviderActivationCoordinator(
            catalog: catalog,
            registry: ProviderRegistry()
        )
        let owner = IntentProviderOwner.plugin(
            id: pluginID,
            installationID: installationID
        )

        await assertActivationRejected(
            .openIntentNotApproved(intentID),
            coordinator: coordinator
        ) {
            try await coordinator.stagePlugin(
                activationCandidate(
                    providerID: ProviderID(pluginID.rawValue),
                    owner: owner,
                    intentIDs: [intentID]
                ),
                authorization: PluginProviderActivationAuthorization(
                    pluginID: pluginID,
                    installationID: installationID,
                    manifestProvidedIntentIDs: [intentID]
                )
            )
        }
    }

    func testRejectsCoreBindingToPluginOwnedContract() async throws {
        let pluginID = PluginID("dev.tenon.git")
        let intentID = try IntentID("dev.tenon.git.stage.v1")
        let catalog = ContractCatalog()
        _ = try await catalog.register(
            activationContract(
                name: intentID,
                contractClass: .pluginOwned,
                owner: .plugin(pluginID)
            )
        )
        let coordinator = ProviderActivationCoordinator(
            catalog: catalog,
            registry: ProviderRegistry()
        )

        await assertActivationRejected(
            .coreCannotProvidePluginOwnedContract(intentID),
            coordinator: coordinator
        ) {
            try await coordinator.stageCore(
                activationCandidate(
                    providerID: ProviderID("dev.tenon.core"),
                    owner: .core,
                    intentIDs: [intentID]
                )
            )
        }
    }
}

private func activationContract(
    name: IntentID,
    contractClass: IntentContractClass,
    owner: IntentContractOwner
) -> IntentContractDeclaration {
    IntentContractDeclaration(
        name: name,
        contractClass: contractClass,
        owner: owner,
        inputSchema: objectSchema(properties: [:]),
        outputSchema: objectSchema(properties: [:]),
        audiences: [.core, .plugin],
        effects: .pessimistic,
        title: nil,
        description: nil,
        deprecated: false,
        domainErrors: []
    )
}

private func activationCandidate(
    providerID: ProviderID,
    owner: IntentProviderOwner,
    intentIDs: [IntentID],
    isExported: Bool = true
) throws -> ProviderGenerationCandidate {
    try ProviderGenerationCandidate(
        providerID: providerID,
        owner: owner,
        principal: owner.principal(sessionRevision: 1),
        generation: 1,
        bindings: intentIDs.map { intentID in
            IntentProviderBinding(intentID: intentID, isExported: isExported) { _, _ in
                .success(.object([:]))
            }
        },
        policyFingerprint: PolicyFingerprint(
            canonicalPolicy: .object(["provider": .string(providerID.rawValue)])
        ),
        mailbox: IntentMailbox(limits: IntentMailboxLimits())
    )
}

private func assertActivationRejected(
    _ expected: ProviderActivationError,
    coordinator: ProviderActivationCoordinator,
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected activation rejection", file: file, line: line)
    } catch {
        XCTAssertEqual(
            error as? ProviderActivationError,
            expected,
            file: file,
            line: line
        )
    }
    let snapshot = await coordinator.snapshot()
    XCTAssertTrue(
        snapshot.generations.isEmpty,
        "Rejected candidate must not mutate the registry",
        file: file,
        line: line
    )
}
