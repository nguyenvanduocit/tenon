import Foundation

public enum IntentDiscoveryProjection: String, Sendable, Equatable, Hashable, Codable {
    case callable
    case catalog
}

public struct IntentDiscoveryRevision: Sendable, Equatable, Hashable {
    public let catalog: UInt64
    public let rules: UInt64
    public let policy: PolicyRevision
    public let providers: ProviderRegistryRevision
    public let principal: IntentPrincipal
    public let projection: IntentDiscoveryProjection

    public init(
        catalog: UInt64,
        rules: UInt64,
        policy: PolicyRevision,
        providers: ProviderRegistryRevision,
        principal: IntentPrincipal,
        projection: IntentDiscoveryProjection
    ) {
        self.catalog = catalog
        self.rules = rules
        self.policy = policy
        self.providers = providers
        self.principal = principal
        self.projection = projection
    }
}

public struct IntentDiscoveryItem: Sendable, Equatable {
    public let name: IntentID
    public let contractClass: IntentContractClass
    public let owner: IntentContractOwner
    public let inputSchema: IntentValue
    public let outputSchema: IntentValue
    public let audiences: Set<IntentAudience>
    public let effects: IntentEffects
    public let title: String?
    public let description: String?
    public let deprecated: Bool
    public let domainErrors: Set<IntentDomainErrorCode>
    public let activeProviders: [ProviderID]

    public var isAvailable: Bool {
        !activeProviders.isEmpty
    }

    public init(contract: IntentContract, activeProviders: [ProviderID]) {
        name = contract.name
        contractClass = contract.contractClass
        owner = contract.owner
        inputSchema = contract.inputSchema.document
        outputSchema = contract.outputSchema.document
        audiences = contract.audiences
        effects = contract.effects
        title = contract.title
        description = contract.description
        deprecated = contract.deprecated
        domainErrors = contract.domainErrors
        self.activeProviders = activeProviders
    }
}

public struct IntentDiscoverySnapshot: Sendable, Equatable {
    public let revision: IntentDiscoveryRevision
    public let items: [IntentDiscoveryItem]

    public init(
        revision: IntentDiscoveryRevision,
        items: [IntentDiscoveryItem]
    ) {
        self.revision = revision
        self.items = items
    }
}

extension PolicySnapshot {
    func discoveryDecision(_ request: PolicyDiscoveryRequest) -> PolicyDecision {
        if request.caller.kind == .plugin,
           declaredUses[request.caller]?.contains(request.intent) != true
        {
            return PolicyDecision(
                verdict: .denied(.undeclaredUse(request.intent)),
                policyRevision: revision
            )
        }
        guard exposures[request.intent]?.discoverableBy
            .contains(request.caller.audience) == true
        else {
            return PolicyDecision(
                verdict: .denied(
                    .intentNotDiscoverable(
                        intent: request.intent,
                        audience: request.caller.audience
                    )
                ),
                policyRevision: revision
            )
        }
        let capabilities = Set(
            (grants[request.caller] ?? []).map(\.capability)
        )
        if let missing = request.requiredCapabilities.sorted(
            by: { $0.rawValue < $1.rawValue }
        ).first(where: { !capabilities.contains($0) }) {
            return PolicyDecision(
                verdict: .denied(.missingCapability(missing)),
                policyRevision: revision
            )
        }
        return PolicyDecision(verdict: .allowed, policyRevision: revision)
    }
}
