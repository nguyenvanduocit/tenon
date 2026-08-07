// @domain: intent-bus
import Foundation
import TenonIntentCore

enum CoreIntentProviderInputError: Error, Sendable, Equatable {
    case expectedObject
    case missingOrInvalidField(String)
}

enum CoreIntentProviderExecutionError: Error, Sendable, Equatable {
    case deadlineExceeded
}

enum CoreIntentProviderSupport {
    static func object(_ value: IntentValue) throws -> [String: IntentValue] {
        guard case let .object(object) = value else {
            throw CoreIntentProviderInputError.expectedObject
        }
        return object
    }

    static func string(
        _ key: String,
        in object: [String: IntentValue]
    ) throws -> String {
        guard case let .string(value)? = object[key] else {
            throw CoreIntentProviderInputError.missingOrInvalidField(key)
        }
        return value
    }

    static func optionalString(
        _ key: String,
        in object: [String: IntentValue]
    ) throws -> String? {
        guard let field = object[key] else { return nil }
        guard case let .string(value) = field else {
            throw CoreIntentProviderInputError.missingOrInvalidField(key)
        }
        return value
    }

    static func optionalInteger(
        _ key: String,
        in object: [String: IntentValue]
    ) throws -> Int64? {
        guard let field = object[key] else { return nil }
        guard case let .integer(value) = field else {
            throw CoreIntentProviderInputError.missingOrInvalidField(key)
        }
        return value
    }

    static func optionalBool(
        _ key: String,
        in object: [String: IntentValue]
    ) throws -> Bool? {
        guard let field = object[key] else { return nil }
        guard case let .bool(value) = field else {
            throw CoreIntentProviderInputError.missingOrInvalidField(key)
        }
        return value
    }

    static func stringArray(
        _ key: String,
        in object: [String: IntentValue]
    ) throws -> [String] {
        guard case let .array(values)? = object[key] else {
            throw CoreIntentProviderInputError.missingOrInvalidField(key)
        }
        return try values.map { value in
            guard case let .string(string) = value else {
                throw CoreIntentProviderInputError.missingOrInvalidField(key)
            }
            return string
        }
    }

    static func optionalObjectArray(
        _ key: String,
        in object: [String: IntentValue]
    ) throws -> [[String: IntentValue]] {
        guard let field = object[key] else { return [] }
        guard case let .array(values) = field else {
            throw CoreIntentProviderInputError.missingOrInvalidField(key)
        }
        return try values.map { value in
            guard case let .object(object) = value else {
                throw CoreIntentProviderInputError.missingOrInvalidField(key)
            }
            return object
        }
    }

    static func optionalTextInput(
        _ key: String,
        in object: [String: IntentValue]
    ) throws -> String? {
        guard let field = object[key] else { return nil }
        guard case let .object(textObject) = field,
              textObject.keys.allSatisfy({
                  ["kind", "text"].contains($0)
              }),
              textObject["kind"] == .string("inline"),
              case let .string(text)? = textObject["text"]
        else {
            throw CoreIntentProviderInputError.missingOrInvalidField(key)
        }
        return text
    }

    static func textOutput(_ text: String) -> IntentValue {
        .object([
            "kind": .string("inline"),
            "text": .string(text),
            "byteCount": .integer(Int64(text.utf8.count)),
        ])
    }

    static func invalidInputFailure(
        _ error: CoreIntentProviderInputError
    ) -> IntentProviderReply {
        let field: String
        switch error {
        case .expectedObject:
            field = "$"
        case let .missingOrInvalidField(name):
            field = name
        }
        return .failure(
            IntentProviderFailure(
                code: .kernel(.invalidInput),
                details: .object(["field": .string(field)])
            )
        )
    }

    static func failure(
        code: IntentErrorCode,
        reason: String,
        retryable: Bool = false
    ) -> IntentProviderReply {
        .failure(
            IntentProviderFailure(
                code: code,
                details: .object(["reason": .string(reason)]),
                retryable: retryable
            )
        )
    }

    static func runBlocking<T: Sendable>(
        deadline: ContinuousClock.Instant,
        context: IntentProviderContext,
        operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try context.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw CoreIntentProviderExecutionError.deadlineExceeded
        }

        let worker = Task.detached(priority: Task.currentPriority) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw CoreIntentProviderExecutionError.deadlineExceeded
            }
            let result = try operation()
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw CoreIntentProviderExecutionError.deadlineExceeded
            }
            return result
        }

        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try context.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw CoreIntentProviderExecutionError.deadlineExceeded
            }
            return result
        } onCancel: {
            worker.cancel()
        }
    }

    static func remainingSeconds(
        until deadline: ContinuousClock.Instant
    ) -> TimeInterval {
        let duration = ContinuousClock.now.duration(to: deadline)
        let components = duration.components
        return max(
            0,
            Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
        )
    }
}
