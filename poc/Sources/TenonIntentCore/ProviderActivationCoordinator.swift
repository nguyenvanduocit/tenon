import Foundation

/// Host-owned proof accompanying one plugin provider generation.
///
/// The manifest set is the complete list this runtime promised to implement. Open-contract
/// approvals are a narrower host decision and never grant access to sealed contracts.
public struct PluginProviderActivationAuthorization: Sendable, Equatable {
    public let pluginID: PluginID
    public let installationID: UUID
    public let manifestProvidedIntentIDs: Set<IntentID>
    public let approvedOpenIntentIDs: Set<IntentID>

    public init(
        pluginID: PluginID,
        installationID: UUID,
        manifestProvidedIntentIDs: Set<IntentID>,
        approvedOpenIntentIDs: Set<IntentID> = []
    ) {
        self.pluginID = pluginID
        self.installationID = installationID
        self.manifestProvidedIntentIDs = manifestProvidedIntentIDs
        self.approvedOpenIntentIDs = approvedOpenIntentIDs
    }
}

public enum ProviderActivationError: Error, Sendable, Equatable {
    case providerOwnerMismatch(
        providerID: ProviderID,
        expected: IntentProviderOwner,
        actual: IntentProviderOwner
    )
    case pluginProviderIdentityMismatch(pluginID: PluginID, providerID: ProviderID)
    case manifestBindingsMismatch(missing: [IntentID], unexpected: [IntentID])
    case unexportedPluginBinding(IntentID)
    case approvedOpenIntentNotDeclared(IntentID)
    case invalidOpenIntentApproval(IntentID)
    case unknownContract(IntentID)
    case sealedContractRequiresCore(IntentID)
    case coreCannotProvidePluginOwnedContract(IntentID)
    case contractOwnerMismatch(
        intentID: IntentID,
        expected: IntentContractOwner,
        actual: IntentContractOwner
    )
    case pluginContractNamespaceMismatch(intentID: IntentID, pluginID: PluginID)
    case openIntentNotApproved(IntentID)
}

/// The only provider staging boundary exposed by `IntentKernelComponents`.
///
/// Contract ownership is checked from one immutable catalog snapshot before the candidate
/// reaches the registry. The registry remains responsible only for generation lifecycle,
/// readiness, routing, and leases.
public final class ProviderActivationCoordinator: Sendable {
    private let catalog: ContractCatalog
    private let registry: ProviderRegistry

    public init(catalog: ContractCatalog, registry: ProviderRegistry) {
        self.catalog = catalog
        self.registry = registry
    }

    public func nextGeneration(for providerID: ProviderID) async throws -> UInt64 {
        try await registry.nextGeneration(for: providerID)
    }

    public func stageCore(_ candidate: ProviderGenerationCandidate) async throws {
        try Self.validateOwner(candidate, expected: .core)
        let snapshot = await catalog.snapshot
        try Self.validateCoreBindings(candidate.bindings, catalog: snapshot)
        try await registry.stage(candidate)
    }

    public func stagePlugin(
        _ candidate: ProviderGenerationCandidate,
        authorization: PluginProviderActivationAuthorization
    ) async throws {
        let expectedOwner = IntentProviderOwner.plugin(
            id: authorization.pluginID,
            installationID: authorization.installationID
        )
        try Self.validateOwner(candidate, expected: expectedOwner)
        guard candidate.providerID.rawValue == authorization.pluginID.rawValue else {
            throw ProviderActivationError.pluginProviderIdentityMismatch(
                pluginID: authorization.pluginID,
                providerID: candidate.providerID
            )
        }

        let boundIntentIDs = Set(candidate.bindings.keys)
        guard boundIntentIDs == authorization.manifestProvidedIntentIDs else {
            throw ProviderActivationError.manifestBindingsMismatch(
                missing: authorization.manifestProvidedIntentIDs
                    .subtracting(boundIntentIDs)
                    .sorted(by: Self.sortIntentIDs),
                unexpected: boundIntentIDs
                    .subtracting(authorization.manifestProvidedIntentIDs)
                    .sorted(by: Self.sortIntentIDs)
            )
        }

        if let unexported = candidate.bindings.values
            .filter({ !$0.isExported })
            .map(\.intentID)
            .sorted(by: Self.sortIntentIDs)
            .first
        {
            throw ProviderActivationError.unexportedPluginBinding(unexported)
        }

        if let undeclaredApproval = authorization.approvedOpenIntentIDs
            .subtracting(authorization.manifestProvidedIntentIDs)
            .sorted(by: Self.sortIntentIDs)
            .first
        {
            throw ProviderActivationError.approvedOpenIntentNotDeclared(
                undeclaredApproval
            )
        }

        let snapshot = await catalog.snapshot
        try Self.validateOpenApprovals(
            authorization.approvedOpenIntentIDs,
            catalog: snapshot
        )
        try Self.validatePluginBindings(
            candidate.bindings,
            pluginID: authorization.pluginID,
            approvedOpenIntentIDs: authorization.approvedOpenIntentIDs,
            catalog: snapshot
        )
        try await registry.stage(candidate)
    }

    public func activate(providerID: ProviderID, generation: UInt64) async throws {
        try await registry.activate(providerID: providerID, generation: generation)
    }

    public func failStaging(
        providerID: ProviderID,
        generation: UInt64,
        diagnostic: String
    ) async throws {
        try await registry.failStaging(
            providerID: providerID,
            generation: generation,
            diagnostic: diagnostic
        )
    }

    public func disable(_ providerID: ProviderID) async throws {
        try await registry.disable(providerID)
    }

    public func uninstall(_ providerID: ProviderID) async throws {
        try await registry.uninstall(providerID)
    }

    public func snapshot() async -> ProviderRegistrySnapshot {
        await registry.snapshot()
    }
}

private extension ProviderActivationCoordinator {
    static func validateOwner(
        _ candidate: ProviderGenerationCandidate,
        expected: IntentProviderOwner
    ) throws {
        guard candidate.owner == expected else {
            throw ProviderActivationError.providerOwnerMismatch(
                providerID: candidate.providerID,
                expected: expected,
                actual: candidate.owner
            )
        }
    }

    static func validateCoreBindings(
        _ bindings: [IntentID: IntentProviderBinding],
        catalog: ContractCatalogSnapshot
    ) throws {
        for intentID in bindings.keys.sorted(by: sortIntentIDs) {
            guard let contract = catalog.contract(named: intentID) else {
                throw ProviderActivationError.unknownContract(intentID)
            }
            switch contract.contractClass {
            case .sealed, .open:
                guard contract.owner == .core else {
                    throw ProviderActivationError.contractOwnerMismatch(
                        intentID: intentID,
                        expected: .core,
                        actual: contract.owner
                    )
                }
            case .pluginOwned:
                throw ProviderActivationError.coreCannotProvidePluginOwnedContract(
                    intentID
                )
            }
        }
    }

    static func validateOpenApprovals(
        _ approvals: Set<IntentID>,
        catalog: ContractCatalogSnapshot
    ) throws {
        for intentID in approvals.sorted(by: sortIntentIDs) {
            guard let contract = catalog.contract(named: intentID),
                  contract.contractClass == .open,
                  contract.owner == .core
            else {
                throw ProviderActivationError.invalidOpenIntentApproval(intentID)
            }
        }
    }

    static func validatePluginBindings(
        _ bindings: [IntentID: IntentProviderBinding],
        pluginID: PluginID,
        approvedOpenIntentIDs: Set<IntentID>,
        catalog: ContractCatalogSnapshot
    ) throws {
        for intentID in bindings.keys.sorted(by: sortIntentIDs) {
            guard let contract = catalog.contract(named: intentID) else {
                throw ProviderActivationError.unknownContract(intentID)
            }

            switch contract.contractClass {
            case .sealed:
                throw ProviderActivationError.sealedContractRequiresCore(intentID)

            case .open:
                guard contract.owner == .core else {
                    throw ProviderActivationError.contractOwnerMismatch(
                        intentID: intentID,
                        expected: .core,
                        actual: contract.owner
                    )
                }
                guard approvedOpenIntentIDs.contains(intentID) else {
                    throw ProviderActivationError.openIntentNotApproved(intentID)
                }

            case .pluginOwned:
                let expectedOwner = IntentContractOwner.plugin(pluginID)
                guard contract.owner == expectedOwner else {
                    throw ProviderActivationError.contractOwnerMismatch(
                        intentID: intentID,
                        expected: expectedOwner,
                        actual: contract.owner
                    )
                }
                guard intentID.rawValue.hasPrefix(pluginID.rawValue + ".") else {
                    throw ProviderActivationError.pluginContractNamespaceMismatch(
                        intentID: intentID,
                        pluginID: pluginID
                    )
                }
            }
        }
    }

    static func sortIntentIDs(_ lhs: IntentID, _ rhs: IntentID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
