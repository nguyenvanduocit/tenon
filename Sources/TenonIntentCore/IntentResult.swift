// @domain: intent-bus
import Foundation

public enum IntentOutcome: String, Sendable, Codable, CaseIterable {
    case notStarted
    case unknown
}

public enum IntentKernelErrorCode: String, Sendable, Codable, CaseIterable {
    case unknownIntent = "tenon.unknown-intent"
    case undeclaredUse = "tenon.undeclared-use"
    case invalidInput = "tenon.invalid-input"
    case denied = "tenon.denied"
    case noProvider = "tenon.no-provider"
    case ambiguousProvider = "tenon.ambiguous-provider"
    case providerUnavailable = "tenon.provider-unavailable"
    case overloaded = "tenon.overloaded"
    case idempotencyConflict = "tenon.idempotency-conflict"
    case cycleDetected = "tenon.cycle-detected"
    case deadlineExceeded = "tenon.deadline-exceeded"
    case cancelled = "tenon.cancelled"
    case providerRetired = "tenon.provider-retired"
    case handlerFailed = "tenon.handler-failed"
    case invalidOutput = "tenon.invalid-output"
    case `internal` = "tenon.internal"
}

public enum IntentErrorCode: Sendable, Equatable, Hashable {
    case kernel(IntentKernelErrorCode)
    case domain(IntentDomainErrorCode)

    public var rawValue: String {
        switch self {
        case let .kernel(code):
            code.rawValue
        case let .domain(code):
            code.rawValue
        }
    }
}

extension IntentErrorCode: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        if let code = IntentKernelErrorCode(rawValue: rawValue) {
            self = .kernel(code)
        } else {
            self = .domain(try IntentDomainErrorCode(rawValue))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct IntentError: Sendable, Equatable, Codable {
    public let code: IntentErrorCode
    public let details: IntentValue?
    public let retryable: Bool
    public let retryAfterMilliseconds: UInt64?
    public let outcome: IntentOutcome

    public init(
        code: IntentErrorCode,
        details: IntentValue?,
        retryable: Bool,
        retryAfterMilliseconds: UInt64?,
        outcome: IntentOutcome
    ) {
        self.code = code
        self.details = details
        self.retryable = retryable
        self.retryAfterMilliseconds = retryAfterMilliseconds
        self.outcome = outcome
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case details
        case retryable
        case retryAfterMilliseconds = "retryAfterMs"
        case outcome
    }
}

public struct IntentSuccessMetadata: Sendable, Equatable, Codable {
    public let requestID: UUID
    public let providerID: ProviderID

    public init(requestID: UUID, providerID: ProviderID) {
        self.requestID = requestID
        self.providerID = providerID
    }
}

public struct IntentFailureMetadata: Sendable, Equatable, Codable {
    public let requestID: UUID
    public let providerID: ProviderID?

    public init(requestID: UUID, providerID: ProviderID?) {
        self.requestID = requestID
        self.providerID = providerID
    }
}

public struct IntentSuccess: Sendable, Equatable, Codable {
    public let value: IntentValue
    public let meta: IntentSuccessMetadata

    public init(value: IntentValue, meta: IntentSuccessMetadata) {
        self.value = value
        self.meta = meta
    }
}

public struct IntentFailure: Sendable, Equatable, Codable {
    public let error: IntentError
    public let meta: IntentFailureMetadata

    public init(error: IntentError, meta: IntentFailureMetadata) {
        self.error = error
        self.meta = meta
    }
}

public enum IntentResult: Sendable, Equatable {
    case success(IntentSuccess)
    case failure(IntentFailure)

    public static func success(
        value: IntentValue,
        requestID: UUID,
        providerID: ProviderID
    ) -> IntentResult {
        .success(
            IntentSuccess(
                value: value,
                meta: IntentSuccessMetadata(requestID: requestID, providerID: providerID)
            )
        )
    }

    public static func failure(
        error: IntentError,
        requestID: UUID,
        providerID: ProviderID?
    ) -> IntentResult {
        .failure(
            IntentFailure(
                error: error,
                meta: IntentFailureMetadata(requestID: requestID, providerID: providerID)
            )
        )
    }
}

extension IntentResult: Codable {
    private enum CodingKeys: String, CodingKey {
        case ok
        case value
        case error
        case meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(Bool.self, forKey: .ok) {
            self = .success(
                IntentSuccess(
                    value: try container.decode(IntentValue.self, forKey: .value),
                    meta: try container.decode(IntentSuccessMetadata.self, forKey: .meta)
                )
            )
        } else {
            self = .failure(
                IntentFailure(
                    error: try container.decode(IntentError.self, forKey: .error),
                    meta: try container.decode(IntentFailureMetadata.self, forKey: .meta)
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .success(success):
            try container.encode(true, forKey: .ok)
            try container.encode(success.value, forKey: .value)
            try container.encode(success.meta, forKey: .meta)
        case let .failure(failure):
            try container.encode(false, forKey: .ok)
            try container.encode(failure.error, forKey: .error)
            try container.encode(failure.meta, forKey: .meta)
        }
    }
}
