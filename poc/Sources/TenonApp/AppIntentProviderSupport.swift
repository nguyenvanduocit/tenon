import Foundation
import TenonIntentCore

enum AppIntentInputError: Error, Sendable, Equatable {
    case expectedObject
    case missingOrInvalidField(String)
}

enum AppIntentProviderSupport {
    static func object(
        _ value: IntentValue
    ) throws -> [String: IntentValue] {
        guard case let .object(object) = value else {
            throw AppIntentInputError.expectedObject
        }
        return object
    }

    static func string(
        _ key: String,
        in object: [String: IntentValue]
    ) throws -> String {
        guard case let .string(value)? = object[key] else {
            throw AppIntentInputError.missingOrInvalidField(key)
        }
        return value
    }

    static func optionalString(
        _ key: String,
        in object: [String: IntentValue]
    ) throws -> String? {
        guard let field = object[key] else {
            return nil
        }
        guard case let .string(value) = field else {
            throw AppIntentInputError.missingOrInvalidField(key)
        }
        return value
    }

    static func bool(
        _ key: String,
        in object: [String: IntentValue]
    ) throws -> Bool {
        guard case let .bool(value)? = object[key] else {
            throw AppIntentInputError.missingOrInvalidField(key)
        }
        return value
    }

    static func optionalBool(
        _ key: String,
        in object: [String: IntentValue]
    ) throws -> Bool? {
        guard let field = object[key] else {
            return nil
        }
        guard case let .bool(value) = field else {
            throw AppIntentInputError.missingOrInvalidField(key)
        }
        return value
    }

    static func optionalInteger(
        _ key: String,
        in object: [String: IntentValue]
    ) throws -> Int? {
        guard let field = object[key] else {
            return nil
        }
        guard case let .integer(value) = field,
              let integer = Int(exactly: value)
        else {
            throw AppIntentInputError.missingOrInvalidField(key)
        }
        return integer
    }

    static func objectArray(
        _ key: String,
        in object: [String: IntentValue]
    ) throws -> [[String: IntentValue]] {
        guard case let .array(values)? = object[key] else {
            throw AppIntentInputError.missingOrInvalidField(key)
        }
        return try values.map { value in
            guard case let .object(item) = value else {
                throw AppIntentInputError.missingOrInvalidField(key)
            }
            return item
        }
    }

    static func invalidInput(
        _ error: AppIntentInputError
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

    static let emptySuccess = IntentProviderReply.success(.object([:]))
}
