import XCTest
@testable import TenonIntentCore

final class IntentSchemaTests: XCTestCase {
    func testCompilesDraft202012ObjectSchemaAndValidatesWithDeterministicPaths() async throws {
        let compiler = IntentSchemaCompiler()
        let schema = objectSchema(
            properties: [
                "command": .object([
                    "type": .string("string"),
                    "minLength": .integer(2),
                ])
            ],
            required: ["command"]
        )

        let compiled = try await compiler.compile(schema)
        let valid = try compiled.validate(.object(["command": .string("ls")]))
        let invalid = try compiled.validate(.object(["command": .integer(1)]))

        XCTAssertTrue(valid.isValid)
        XCTAssertEqual(
            invalid.violations,
            [
                IntentSchemaViolation(
                    instancePath: "/command",
                    schemaPath: "/properties/command/type",
                    keyword: "type"
                )
            ]
        )
        XCTAssertEqual(compiled.digest, try schema.canonicalSHA256Digest())
    }

    func testRejectsMissingOrDifferentDialect() async {
        let compiler = IntentSchemaCompiler()
        let missing: IntentValue = .object(["type": .string("object")])
        let wrong: IntentValue = .object([
            "$schema": .string("http://json-schema.org/draft-07/schema#"),
            "type": .string("object"),
        ])

        await XCTAssertThrowsErrorAsync(try await compiler.compile(missing)) { error in
            XCTAssertEqual(error as? IntentSchemaError, .missingDialect)
        }
        await XCTAssertThrowsErrorAsync(try await compiler.compile(wrong)) { error in
            XCTAssertEqual(
                error as? IntentSchemaError,
                .unsupportedDialect("http://json-schema.org/draft-07/schema#")
            )
        }
    }

    func testRequiresInputAndOutputSchemaRootsToDescribeObjects() async {
        let compiler = IntentSchemaCompiler()
        let scalarSchema: IntentValue = .object([
            "$schema": .string(IntentSchemaDialect.draft202012.rawValue),
            "type": .string("string"),
        ])

        await XCTAssertThrowsErrorAsync(try await compiler.compile(scalarSchema)) { error in
            XCTAssertEqual(error as? IntentSchemaError, .rootTypeMustBeObject)
        }
    }

    func testUsesOfficialMetaSchemaValidationAtCompilation() async {
        let compiler = IntentSchemaCompiler()
        let invalid: IntentValue = .object([
            "$schema": .string(IntentSchemaDialect.draft202012.rawValue),
            "type": .string("object"),
            "required": .string("name"),
        ])

        await XCTAssertThrowsErrorAsync(try await compiler.compile(invalid)) { error in
            guard case .invalidSchema = error as? IntentSchemaError else {
                return XCTFail("Expected official validator to reject malformed required")
            }
        }
    }

    func testAllowsLocalDefinitionsAndRejectsRemoteReferences() async throws {
        let compiler = IntentSchemaCompiler()
        let local: IntentValue = .object([
            "$schema": .string(IntentSchemaDialect.draft202012.rawValue),
            "type": .string("object"),
            "$defs": .object([
                "command": .object(["type": .string("string")])
            ]),
            "properties": .object([
                "command": .object(["$ref": .string("#/$defs/command")])
            ]),
        ])
        let remote: IntentValue = .object([
            "$schema": .string(IntentSchemaDialect.draft202012.rawValue),
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "$ref": .string("https://example.com/schema.json")
                ])
            ]),
        ])

        let compiled = try await compiler.compile(local)
        XCTAssertTrue(
            try compiled.validate(.object(["command": .string("ls")])).isValid
        )

        await XCTAssertThrowsErrorAsync(try await compiler.compile(remote)) { error in
            XCTAssertEqual(
                error as? IntentSchemaError,
                .nonLocalReference("https://example.com/schema.json")
            )
        }
    }

    func testEnforcesDepthReferenceRegexAndCollectionBoundsBeforeCompilation() async {
        let compiler = IntentSchemaCompiler(
            limits: IntentSchemaLimits(
                maxEncodedBytes: 4_096,
                maxSchemaDepth: 4,
                maxReferenceDepth: 2,
                maxRegexLength: 4,
                maxCollectionCount: 5,
                maxValidationErrors: 8
            )
        )
        let deep: IntentValue = .object([
            "$schema": .string(IntentSchemaDialect.draft202012.rawValue),
            "type": .string("object"),
            "properties": .object([
                "nested": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "value": .object(["type": .string("string")])
                    ]),
                ])
            ]),
        ])
        let longRegex = objectSchema(
            properties: [
                "name": .object([
                    "type": .string("string"),
                    "pattern": .string("12345"),
                ])
            ]
        )
        let tooManyProperties = objectSchema(
            properties: [
                "a": .object(["type": .string("string")]),
                "b": .object(["type": .string("string")]),
                "c": .object(["type": .string("string")]),
                "d": .object(["type": .string("string")]),
                "e": .object(["type": .string("string")]),
                "f": .object(["type": .string("string")]),
            ]
        )
        let referenceChain: IntentValue = .object([
            "$schema": .string(IntentSchemaDialect.draft202012.rawValue),
            "type": .string("object"),
            "$defs": .object([
                "a": .object(["$ref": .string("#/$defs/b")]),
                "b": .object(["$ref": .string("#/$defs/c")]),
                "c": .object(["type": .string("object")]),
            ]),
            "allOf": .array([
                .object(["$ref": .string("#/$defs/a")])
            ]),
        ])

        await assertLimit(.schemaDepth, compiling: deep, with: compiler)
        await assertLimit(.regexLength, compiling: longRegex, with: compiler)
        await assertLimit(.collectionCount, compiling: tooManyProperties, with: compiler)
        await assertLimit(.referenceDepth, compiling: referenceChain, with: compiler)
    }

    func testCachesCompiledValidatorByCanonicalDigest() async throws {
        let compiler = IntentSchemaCompiler()
        let first = objectSchema(properties: [:])
        let sameWithDifferentInsertionOrder: IntentValue = .object([
            "type": .string("object"),
            "$schema": .string(IntentSchemaDialect.draft202012.rawValue),
            "additionalProperties": .bool(false),
        ])
        let firstWithAdditionalProperties: IntentValue = .object([
            "$schema": .string(IntentSchemaDialect.draft202012.rawValue),
            "additionalProperties": .bool(false),
            "type": .string("object"),
        ])

        _ = try await compiler.compile(first)
        _ = try await compiler.compile(firstWithAdditionalProperties)
        _ = try await compiler.compile(sameWithDifferentInsertionOrder)

        let cachedSchemaCount = await compiler.cachedSchemaCount
        XCTAssertEqual(cachedSchemaCount, 2)
    }

    func testRegexLimitDoesNotApplyToOrdinaryPropertyNames() async throws {
        let compiler = IntentSchemaCompiler(
            limits: IntentSchemaLimits(
                maxEncodedBytes: 4_096,
                maxSchemaDepth: 16,
                maxReferenceDepth: 8,
                maxRegexLength: 4,
                maxCollectionCount: 16,
                maxValidationErrors: 8
            )
        )
        let schema = objectSchema(
            properties: [
                "ordinaryPropertyName": .object(["type": .string("string")])
            ]
        )

        _ = try await compiler.compile(schema)
    }

    private func assertLimit(
        _ expected: IntentSchemaLimit,
        compiling schema: IntentValue,
        with compiler: IntentSchemaCompiler
    ) async {
        await XCTAssertThrowsErrorAsync(try await compiler.compile(schema)) { error in
            guard case let .limitExceeded(limit) = error as? IntentSchemaError else {
                return XCTFail("Expected \(expected), received \(error)")
            }
            XCTAssertEqual(limit, expected)
        }
    }
}
