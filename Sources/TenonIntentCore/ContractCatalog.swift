// @domain: intent-bus
import Foundation

public struct ContractCatalogSnapshot: Sendable, Equatable {
    public static let empty = ContractCatalogSnapshot(revision: 0, contracts: [:])

    public let revision: UInt64
    public let contracts: [IntentID: IntentContract]

    public init(revision: UInt64, contracts: [IntentID: IntentContract]) {
        self.revision = revision
        self.contracts = contracts
    }

    public func contract(named name: IntentID) -> IntentContract? {
        contracts[name]
    }

    public var allContracts: [IntentContract] {
        contracts.values.sorted { $0.name.rawValue < $1.name.rawValue }
    }
}

public enum ContractCompatibilityFailure: String, Sendable, Equatable, Codable {
    case contractClassChanged
    case ownerChanged
    case inputSchemaChanged
    case outputSchemaChanged
    case audiencesChanged
    case effectsChanged
    case domainErrorRemoved
}

public enum ContractCatalogError: Error, Sendable, Equatable {
    case emptyAudiences
    case coreOwnershipRequired
    case pluginOwnershipRequired
    case pluginNamespaceMismatch(intent: String, owner: String)
    case domainErrorNamespaceMismatch(code: String, owner: String)
    case incompatibleUpdate(ContractCompatibilityFailure)
    case revisionOverflow
}

public actor ContractCatalog {
    private let compiler: IntentSchemaCompiler
    private var currentSnapshot: ContractCatalogSnapshot = .empty

    public init(compiler: IntentSchemaCompiler = IntentSchemaCompiler()) {
        self.compiler = compiler
    }

    public var snapshot: ContractCatalogSnapshot {
        currentSnapshot
    }

    @discardableResult
    public func register(
        _ declaration: IntentContractDeclaration
    ) async throws -> ContractCatalogSnapshot {
        try Self.validateOwnership(of: declaration)

        async let inputSchema = compiler.compile(declaration.inputSchema)
        async let outputSchema = compiler.compile(declaration.outputSchema)
        let candidate = try await IntentContract(
            declaration: declaration,
            inputSchema: inputSchema,
            outputSchema: outputSchema
        )

        if let existing = currentSnapshot.contracts[declaration.name] {
            if existing == candidate {
                return currentSnapshot
            }
            try Self.validateCompatibleUpdate(from: existing, to: candidate)
        }

        guard currentSnapshot.revision < UInt64.max else {
            throw ContractCatalogError.revisionOverflow
        }
        var contracts = currentSnapshot.contracts
        contracts[declaration.name] = candidate
        currentSnapshot = ContractCatalogSnapshot(
            revision: currentSnapshot.revision + 1,
            contracts: contracts
        )
        return currentSnapshot
    }
}

private extension ContractCatalog {
    static func validateOwnership(of declaration: IntentContractDeclaration) throws {
        guard !declaration.audiences.isEmpty else {
            throw ContractCatalogError.emptyAudiences
        }

        switch (declaration.contractClass, declaration.owner) {
        case (.sealed, .core), (.open, .core):
            break
        case (.sealed, .plugin), (.open, .plugin):
            throw ContractCatalogError.coreOwnershipRequired
        case (.pluginOwned, .core):
            throw ContractCatalogError.pluginOwnershipRequired
        case let (.pluginOwned, .plugin(pluginID)):
            let namespace = pluginID.rawValue + "."
            guard declaration.name.rawValue.hasPrefix(namespace) else {
                throw ContractCatalogError.pluginNamespaceMismatch(
                    intent: declaration.name.rawValue,
                    owner: pluginID.rawValue
                )
            }
            for code in declaration.domainErrors
            where !code.rawValue.hasPrefix(namespace) {
                throw ContractCatalogError.domainErrorNamespaceMismatch(
                    code: code.rawValue,
                    owner: pluginID.rawValue
                )
            }
        }
    }

    static func validateCompatibleUpdate(
        from existing: IntentContract,
        to candidate: IntentContract
    ) throws {
        guard existing.contractClass == candidate.contractClass else {
            throw ContractCatalogError.incompatibleUpdate(.contractClassChanged)
        }
        guard existing.owner == candidate.owner else {
            throw ContractCatalogError.incompatibleUpdate(.ownerChanged)
        }
        guard existing.inputSchema.executableDigest == candidate.inputSchema.executableDigest else {
            throw ContractCatalogError.incompatibleUpdate(.inputSchemaChanged)
        }
        guard existing.outputSchema.executableDigest == candidate.outputSchema.executableDigest else {
            throw ContractCatalogError.incompatibleUpdate(.outputSchemaChanged)
        }
        guard existing.audiences == candidate.audiences else {
            throw ContractCatalogError.incompatibleUpdate(.audiencesChanged)
        }
        guard existing.effects == candidate.effects else {
            throw ContractCatalogError.incompatibleUpdate(.effectsChanged)
        }
        guard candidate.domainErrors.isSuperset(of: existing.domainErrors) else {
            throw ContractCatalogError.incompatibleUpdate(.domainErrorRemoved)
        }
    }
}
