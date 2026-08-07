// @domain: intent-bus
import Foundation
import JSONSchema

public enum IntentSchemaDialect: String, Sendable, Codable, CaseIterable {
    case draft202012 = "https://json-schema.org/draft/2020-12/schema"
}

public struct IntentSchemaLimits: Sendable, Equatable {
    public static let `default` = IntentSchemaLimits(
        maxEncodedBytes: 256 * 1024,
        maxSchemaDepth: 64,
        maxReferenceDepth: 32,
        maxRegexLength: 1_024,
        maxCollectionCount: 1_024,
        maxValidationErrors: 32
    )

    public let maxEncodedBytes: Int
    public let maxSchemaDepth: Int
    public let maxReferenceDepth: Int
    public let maxRegexLength: Int
    public let maxCollectionCount: Int
    public let maxValidationErrors: Int

    public init(
        maxEncodedBytes: Int,
        maxSchemaDepth: Int,
        maxReferenceDepth: Int,
        maxRegexLength: Int,
        maxCollectionCount: Int,
        maxValidationErrors: Int
    ) {
        self.maxEncodedBytes = maxEncodedBytes
        self.maxSchemaDepth = maxSchemaDepth
        self.maxReferenceDepth = maxReferenceDepth
        self.maxRegexLength = maxRegexLength
        self.maxCollectionCount = maxCollectionCount
        self.maxValidationErrors = maxValidationErrors
    }
}

public enum IntentSchemaLimit: String, Sendable, Codable, CaseIterable {
    case encodedBytes
    case schemaDepth
    case referenceDepth
    case regexLength
    case collectionCount
    case validationErrors
}

public struct IntentSchemaViolation: Sendable, Equatable, Hashable, Codable {
    public let instancePath: String
    public let schemaPath: String
    public let keyword: String

    public init(instancePath: String, schemaPath: String, keyword: String) {
        self.instancePath = instancePath
        self.schemaPath = schemaPath
        self.keyword = keyword
    }
}

public struct IntentSchemaValidation: Sendable, Equatable {
    public let isValid: Bool
    public let violations: [IntentSchemaViolation]

    public init(isValid: Bool, violations: [IntentSchemaViolation]) {
        self.isValid = isValid
        self.violations = violations
    }
}

public enum IntentSchemaError: Error, Sendable, Equatable {
    case invalidLimits
    case missingDialect
    case unsupportedDialect(String)
    case nestedDialect
    case rootTypeMustBeObject
    case nonLocalReference(String)
    case unsupportedLocalReference(String)
    case unresolvedLocalReference(String)
    case referenceCycle(String)
    case unsupportedKeyword(String)
    case limitExceeded(IntentSchemaLimit)
    case invalidSchema([IntentSchemaViolation])
    case digestCollision
    case invalidInteger
}

public struct CompiledIntentSchema: Sendable, Equatable {
    public let document: IntentValue
    public let digest: IntentDigest
    public let executableDigest: IntentDigest

    private let schema: Schema
    private let maximumValidationErrors: Int

    init(
        document: IntentValue,
        digest: IntentDigest,
        executableDigest: IntentDigest,
        schema: Schema,
        maximumValidationErrors: Int
    ) {
        self.document = document
        self.digest = digest
        self.executableDigest = executableDigest
        self.schema = schema
        self.maximumValidationErrors = maximumValidationErrors
    }

    public static func == (lhs: CompiledIntentSchema, rhs: CompiledIntentSchema) -> Bool {
        lhs.digest == rhs.digest && lhs.document == rhs.document
    }

    public func validate(_ value: IntentValue) throws -> IntentSchemaValidation {
        try value.validate()
        let result = schema.validate(try value.jsonSchemaValue())
        let violations = Self.violations(
            from: result,
            maximumCount: maximumValidationErrors
        )
        return IntentSchemaValidation(isValid: result.isValid, violations: violations)
    }
}

public actor IntentSchemaCompiler {
    private let limits: IntentSchemaLimits
    private var cache: [IntentDigest: CompiledIntentSchema] = [:]

    public init(limits: IntentSchemaLimits = .default) {
        self.limits = limits
    }

    public var cachedSchemaCount: Int {
        cache.count
    }

    public func compile(_ document: IntentValue) throws -> CompiledIntentSchema {
        try Self.validate(limits)
        try Self.validateProfile(document, limits: limits)

        let valueLimits = IntentValueLimits(
            maxEncodedBytes: limits.maxEncodedBytes,
            maxDepth: limits.maxSchemaDepth,
            maxValueCount: 16_384,
            maxCollectionCount: limits.maxCollectionCount,
            maxStringBytes: limits.maxEncodedBytes,
            maxObjectKeyBytes: limits.maxEncodedBytes
        )
        let digest: IntentDigest
        do {
            digest = try document.canonicalSHA256Digest(limits: valueLimits)
        } catch let error as IntentValueError {
            throw Self.schemaLimitError(for: error)
        }

        if let compiled = cache[digest] {
            guard compiled.document == document else {
                throw IntentSchemaError.digestCollision
            }
            return compiled
        }

        let schema: Schema
        do {
            schema = try Schema(
                rawSchema: document.jsonSchemaValue(),
                context: Context(dialect: .draft2020_12)
            )
        } catch {
            throw IntentSchemaError.invalidSchema([])
        }

        let metaValidation: ValidationResult
        do {
            metaValidation = try schema.validateAgainstMetaSchema()
        } catch {
            throw IntentSchemaError.invalidSchema([])
        }
        guard metaValidation.isValid else {
            throw IntentSchemaError.invalidSchema(
                CompiledIntentSchema.violations(
                    from: metaValidation,
                    maximumCount: limits.maxValidationErrors
                )
            )
        }

        let compiled = CompiledIntentSchema(
            document: document,
            digest: digest,
            executableDigest: try document
                .schemaCompatibilityDocument()
                .canonicalSHA256Digest(limits: valueLimits),
            schema: schema,
            maximumValidationErrors: limits.maxValidationErrors
        )
        cache[digest] = compiled
        return compiled
    }
}

private extension IntentSchemaCompiler {
    static func validate(_ limits: IntentSchemaLimits) throws {
        guard limits.maxEncodedBytes > 0,
              limits.maxEncodedBytes <= IntentValueLimits.hardMaximumEncodedBytes,
              limits.maxSchemaDepth > 0,
              limits.maxReferenceDepth > 0,
              limits.maxRegexLength > 0,
              limits.maxCollectionCount > 0,
              limits.maxValidationErrors > 0
        else {
            throw IntentSchemaError.invalidLimits
        }
    }

    static func validateProfile(
        _ document: IntentValue,
        limits: IntentSchemaLimits
    ) throws {
        guard case let .object(root) = document else {
            throw IntentSchemaError.rootTypeMustBeObject
        }
        guard let dialect = root["$schema"] else {
            throw IntentSchemaError.missingDialect
        }
        guard case let .string(dialectURI) = dialect,
              dialectURI == IntentSchemaDialect.draft202012.rawValue
        else {
            let value = dialect.stringValue ?? ""
            throw IntentSchemaError.unsupportedDialect(value)
        }
        guard root["type"] == .string("object") else {
            throw IntentSchemaError.rootTypeMustBeObject
        }

        var references: [String] = []
        try inspect(
            document,
            depth: 1,
            isRoot: true,
            limits: limits,
            references: &references
        )
        for reference in references {
            try validateReference(
                reference,
                in: document,
                depth: 1,
                stack: [],
                limits: limits
            )
        }
    }

    static func inspect(
        _ value: IntentValue,
        depth: Int,
        isRoot: Bool,
        limits: IntentSchemaLimits,
        references: inout [String]
    ) throws {
        guard depth <= limits.maxSchemaDepth else {
            throw IntentSchemaError.limitExceeded(.schemaDepth)
        }

        switch value {
        case let .array(values):
            guard values.count <= limits.maxCollectionCount else {
                throw IntentSchemaError.limitExceeded(.collectionCount)
            }
            for value in values {
                try inspect(
                    value,
                    depth: depth + 1,
                    isRoot: false,
                    limits: limits,
                    references: &references
                )
            }

        case let .object(values):
            guard values.count <= limits.maxCollectionCount else {
                throw IntentSchemaError.limitExceeded(.collectionCount)
            }
            if !isRoot, values["$schema"] != nil {
                throw IntentSchemaError.nestedDialect
            }
            for keyword in ["$vocabulary", "$dynamicRef", "$dynamicAnchor", "$recursiveRef"] {
                if values[keyword] != nil {
                    throw IntentSchemaError.unsupportedKeyword(keyword)
                }
            }
            if let reference = values["$ref"]?.stringValue {
                guard reference == "#" || reference.hasPrefix("#/") else {
                    throw IntentSchemaError.nonLocalReference(reference)
                }
                references.append(reference)
            }
            if let pattern = values["pattern"]?.stringValue,
               pattern.utf8.count > limits.maxRegexLength
            {
                throw IntentSchemaError.limitExceeded(.regexLength)
            }
            if case let .object(patterns)? = values["patternProperties"] {
                guard patterns.keys.allSatisfy({ $0.utf8.count <= limits.maxRegexLength }) else {
                    throw IntentSchemaError.limitExceeded(.regexLength)
                }
            }
            for value in values.values {
                try inspect(
                    value,
                    depth: depth + 1,
                    isRoot: false,
                    limits: limits,
                    references: &references
                )
            }

        case .null, .bool, .integer, .number, .string:
            break
        }
    }

    static func validateReference(
        _ reference: String,
        in document: IntentValue,
        depth: Int,
        stack: Set<String>,
        limits: IntentSchemaLimits
    ) throws {
        guard depth <= limits.maxReferenceDepth else {
            throw IntentSchemaError.limitExceeded(.referenceDepth)
        }
        guard !stack.contains(reference) else {
            throw IntentSchemaError.referenceCycle(reference)
        }
        guard let target = try document.value(atLocalReference: reference) else {
            throw IntentSchemaError.unresolvedLocalReference(reference)
        }

        var nestedReferences: [String] = []
        collectReferences(in: target, into: &nestedReferences)
        var nextStack = stack
        nextStack.insert(reference)
        for nestedReference in nestedReferences {
            try validateReference(
                nestedReference,
                in: document,
                depth: depth + 1,
                stack: nextStack,
                limits: limits
            )
        }
    }

    static func collectReferences(in value: IntentValue, into references: inout [String]) {
        switch value {
        case let .array(values):
            for value in values {
                collectReferences(in: value, into: &references)
            }
        case let .object(values):
            if let reference = values["$ref"]?.stringValue {
                references.append(reference)
            }
            for value in values.values {
                collectReferences(in: value, into: &references)
            }
        case .null, .bool, .integer, .number, .string:
            break
        }
    }

    static func schemaLimitError(for error: IntentValueError) -> IntentSchemaError {
        switch error {
        case .maximumEncodedBytesExceeded:
            .limitExceeded(.encodedBytes)
        case .maximumDepthExceeded:
            .limitExceeded(.schemaDepth)
        case .maximumCollectionCountExceeded:
            .limitExceeded(.collectionCount)
        case .maximumObjectKeyBytesExceeded:
            .limitExceeded(.encodedBytes)
        default:
            .invalidSchema([])
        }
    }
}

private extension CompiledIntentSchema {
    static func violations(
        from result: ValidationResult,
        maximumCount: Int
    ) -> [IntentSchemaViolation] {
        var flattened: [IntentSchemaViolation] = []
        for error in result.errors ?? [] {
            flatten(error, into: &flattened)
        }
        if !result.isValid, flattened.isEmpty {
            flattened.append(
                IntentSchemaViolation(
                    instancePath: result.instanceLocation.jsonPointerString,
                    schemaPath: result.keywordLocation.jsonPointerString,
                    keyword: "schema"
                )
            )
        }
        return Array(
            flattened
                .sorted {
                    ($0.instancePath, $0.schemaPath, $0.keyword)
                        < ($1.instancePath, $1.schemaPath, $1.keyword)
                }
                .prefix(maximumCount)
        )
    }

    static func flatten(
        _ error: ValidationError,
        into violations: inout [IntentSchemaViolation]
    ) {
        if let nested = error.errors, !nested.isEmpty {
            for error in nested {
                flatten(error, into: &violations)
            }
            return
        }
        violations.append(
            IntentSchemaViolation(
                instancePath: error.instanceLocation.jsonPointerString,
                schemaPath: error.keywordLocation.jsonPointerString,
                keyword: error.keyword
            )
        )
    }
}

private extension IntentValue {
    var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }

    func jsonSchemaValue() throws -> JSONValue {
        switch self {
        case .null:
            return .null
        case let .bool(value):
            return .boolean(value)
        case let .integer(value):
            guard let value = Int(exactly: value) else {
                throw IntentSchemaError.invalidInteger
            }
            return .integer(value)
        case let .number(value):
            guard value.isFinite else {
                throw IntentValueError.nonFiniteNumber
            }
            return .number(value)
        case let .string(value):
            return .string(value)
        case let .array(values):
            return .array(try values.map { try $0.jsonSchemaValue() })
        case let .object(values):
            let emptyObject: JSONValue = [:]
            guard case var .object(orderedValues) = emptyObject else {
                throw IntentSchemaError.invalidSchema([])
            }
            for key in values.keys.sorted() {
                guard let value = values[key] else {
                    continue
                }
                orderedValues[key] = try value.jsonSchemaValue()
            }
            return .object(orderedValues)
        }
    }

    func value(atLocalReference reference: String) throws -> IntentValue? {
        guard reference == "#" || reference.hasPrefix("#/") else {
            throw IntentSchemaError.unsupportedLocalReference(reference)
        }
        guard reference != "#" else {
            return self
        }

        var current = self
        let encodedTokens = reference.dropFirst(2).split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        for encodedToken in encodedTokens {
            guard let percentDecoded = String(encodedToken).removingPercentEncoding,
                  let token = Self.decodeJSONPointerToken(percentDecoded)
            else {
                throw IntentSchemaError.unsupportedLocalReference(reference)
            }
            switch current {
            case let .object(values):
                guard let next = values[token] else {
                    return nil
                }
                current = next
            case let .array(values):
                guard let index = Int(token), values.indices.contains(index) else {
                    return nil
                }
                current = values[index]
            default:
                return nil
            }
        }
        return current
    }

    static func decodeJSONPointerToken(_ encoded: String) -> String? {
        var result = ""
        var index = encoded.startIndex
        while index < encoded.endIndex {
            if encoded[index] != "~" {
                result.append(encoded[index])
                index = encoded.index(after: index)
                continue
            }
            let next = encoded.index(after: index)
            guard next < encoded.endIndex else {
                return nil
            }
            switch encoded[next] {
            case "0":
                result.append("~")
            case "1":
                result.append("/")
            default:
                return nil
            }
            index = encoded.index(after: next)
        }
        return result
    }

    func schemaCompatibilityDocument() -> IntentValue {
        guard case let .object(fields) = self else {
            return self
        }

        let annotationKeywords: Set<String> = [
            "title",
            "description",
            "examples",
            "deprecated",
        ]
        let schemaMapKeywords: Set<String> = [
            "$defs",
            "definitions",
            "properties",
            "patternProperties",
            "dependentSchemas",
        ]
        let schemaKeywords: Set<String> = [
            "additionalItems",
            "additionalProperties",
            "contains",
            "contentSchema",
            "else",
            "if",
            "items",
            "not",
            "propertyNames",
            "then",
            "unevaluatedItems",
            "unevaluatedProperties",
        ]
        let schemaArrayKeywords: Set<String> = [
            "allOf",
            "anyOf",
            "oneOf",
            "prefixItems",
        ]

        var result = fields.filter { !annotationKeywords.contains($0.key) }
        for (keyword, value) in result {
            if schemaMapKeywords.contains(keyword), case let .object(schemas) = value {
                result[keyword] = .object(
                    schemas.mapValues { $0.schemaCompatibilityDocument() }
                )
            } else if schemaKeywords.contains(keyword) {
                result[keyword] = value.schemaCompatibilityDocument()
            } else if schemaArrayKeywords.contains(keyword), case let .array(schemas) = value {
                result[keyword] = .array(
                    schemas.map { $0.schemaCompatibilityDocument() }
                )
            }
        }
        return .object(result)
    }
}
