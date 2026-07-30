import Foundation

public enum IntentContractClass: String, Sendable, Equatable, Hashable, Codable {
    case sealed
    case open
    case pluginOwned
}

public enum IntentContractOwner: Sendable, Equatable, Hashable {
    case core
    case plugin(PluginID)
}

public enum IntentContractValueLocation: String, Sendable, Equatable, Hashable, Codable {
    case input
    case output
}

public struct IntentContractValidationIssue: Sendable, Equatable, Hashable, Codable {
    public let location: IntentContractValueLocation
    public let instancePath: String
    public let schemaPath: String
    public let keyword: String

    public init(
        location: IntentContractValueLocation,
        instancePath: String,
        schemaPath: String,
        keyword: String
    ) {
        self.location = location
        self.instancePath = instancePath
        self.schemaPath = schemaPath
        self.keyword = keyword
    }
}

public struct IntentContractValidation: Sendable, Equatable {
    public let isValid: Bool
    public let issues: [IntentContractValidationIssue]

    public init(isValid: Bool, issues: [IntentContractValidationIssue]) {
        self.isValid = isValid
        self.issues = issues
    }
}

public struct IntentContractDeclaration: Sendable, Equatable {
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

    public init(
        name: IntentID,
        contractClass: IntentContractClass,
        owner: IntentContractOwner,
        inputSchema: IntentValue,
        outputSchema: IntentValue,
        audiences: Set<IntentAudience>,
        effects: IntentEffects,
        title: String?,
        description: String?,
        deprecated: Bool,
        domainErrors: Set<IntentDomainErrorCode>
    ) {
        self.name = name
        self.contractClass = contractClass
        self.owner = owner
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.audiences = audiences
        self.effects = effects
        self.title = title
        self.description = description
        self.deprecated = deprecated
        self.domainErrors = domainErrors
    }
}

public struct IntentContract: Sendable, Equatable {
    public let name: IntentID
    public let contractClass: IntentContractClass
    public let owner: IntentContractOwner
    public let inputSchema: CompiledIntentSchema
    public let outputSchema: CompiledIntentSchema
    public let audiences: Set<IntentAudience>
    public let effects: IntentEffects
    public let title: String?
    public let description: String?
    public let deprecated: Bool
    public let domainErrors: Set<IntentDomainErrorCode>

    init(
        declaration: IntentContractDeclaration,
        inputSchema: CompiledIntentSchema,
        outputSchema: CompiledIntentSchema
    ) {
        self.name = declaration.name
        self.contractClass = declaration.contractClass
        self.owner = declaration.owner
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.audiences = declaration.audiences
        self.effects = declaration.effects
        self.title = declaration.title
        self.description = declaration.description
        self.deprecated = declaration.deprecated
        self.domainErrors = declaration.domainErrors
    }

    public func validateInput(_ value: IntentValue) throws -> IntentContractValidation {
        try validation(for: value, schema: inputSchema, location: .input)
    }

    public func validateOutput(_ value: IntentValue) throws -> IntentContractValidation {
        try validation(for: value, schema: outputSchema, location: .output)
    }

    private func validation(
        for value: IntentValue,
        schema: CompiledIntentSchema,
        location: IntentContractValueLocation
    ) throws -> IntentContractValidation {
        let validation = try schema.validate(value)
        return IntentContractValidation(
            isValid: validation.isValid,
            issues: validation.violations.map {
                IntentContractValidationIssue(
                    location: location,
                    instancePath: $0.instancePath,
                    schemaPath: $0.schemaPath,
                    keyword: $0.keyword
                )
            }
        )
    }
}
