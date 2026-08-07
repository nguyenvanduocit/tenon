import XCTest
@testable import TenonIntentCore

func objectSchema(
    properties: [String: IntentValue],
    required: [String] = []
) -> IntentValue {
    var fields: [String: IntentValue] = [
        "$schema": .string(IntentSchemaDialect.draft202012.rawValue),
        "type": .string("object"),
        "properties": .object(properties),
        "additionalProperties": .bool(false),
    ]
    if !required.isEmpty {
        fields["required"] = .array(required.map(IntentValue.string))
    }
    return .object(fields)
}

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
