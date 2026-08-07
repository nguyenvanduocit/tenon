// @domain: intent-bus
import CryptoKit
import Foundation

/// An owned JSON value that is safe to move across isolation boundaries.
public indirect enum IntentValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([IntentValue])
    case object([String: IntentValue])
}

public struct IntentValueLimits: Sendable, Equatable {
    public static let hardMaximumEncodedBytes = 1024 * 1024

    public static let `default` = IntentValueLimits(
        maxEncodedBytes: 64 * 1024,
        maxDepth: 64,
        maxValueCount: 4_096,
        maxCollectionCount: 1_024,
        maxStringBytes: 64 * 1024,
        maxObjectKeyBytes: 1_024
    )

    public let maxEncodedBytes: Int
    public let maxDepth: Int
    public let maxValueCount: Int
    public let maxCollectionCount: Int
    public let maxStringBytes: Int
    public let maxObjectKeyBytes: Int

    public init(
        maxEncodedBytes: Int,
        maxDepth: Int,
        maxValueCount: Int,
        maxCollectionCount: Int,
        maxStringBytes: Int,
        maxObjectKeyBytes: Int
    ) {
        self.maxEncodedBytes = maxEncodedBytes
        self.maxDepth = maxDepth
        self.maxValueCount = maxValueCount
        self.maxCollectionCount = maxCollectionCount
        self.maxStringBytes = maxStringBytes
        self.maxObjectKeyBytes = maxObjectKeyBytes
    }
}

public struct IntentValueAccounting: Sendable, Equatable {
    public let encodedBytes: Int
    public let maximumDepth: Int
    public let valueCount: Int

    public init(encodedBytes: Int, maximumDepth: Int, valueCount: Int) {
        self.encodedBytes = encodedBytes
        self.maximumDepth = maximumDepth
        self.valueCount = valueCount
    }
}

public struct IntentDigest: Sendable, Equatable, Hashable, Codable {
    public let hex: String

    init(bytes: SHA256.Digest) {
        self.hex = bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public enum IntentValueError: Error, Sendable, Equatable {
    case invalidLimits
    case invalidJSON
    case nonFiniteNumber
    case maximumEncodedBytesExceeded(limit: Int)
    case maximumDepthExceeded(limit: Int)
    case maximumValueCountExceeded(limit: Int)
    case maximumCollectionCountExceeded(limit: Int)
    case maximumStringBytesExceeded(limit: Int)
    case maximumObjectKeyBytesExceeded(limit: Int)
}

public extension IntentValue {
    init(jsonData: Data, limits: IntentValueLimits = .default) throws {
        try Self.validate(limits)
        guard jsonData.count <= limits.maxEncodedBytes else {
            throw IntentValueError.maximumEncodedBytesExceeded(limit: limits.maxEncodedBytes)
        }

        do {
            self = try JSONDecoder().decode(IntentValue.self, from: jsonData)
        } catch let error as IntentValueError {
            throw error
        } catch {
            throw IntentValueError.invalidJSON
        }

        try validate(limits: limits)
    }

    func validate(limits: IntentValueLimits = .default) throws {
        _ = try validatedRepresentation(limits: limits)
    }

    func accounting(limits: IntentValueLimits = .default) throws -> IntentValueAccounting {
        try validatedRepresentation(limits: limits).accounting
    }

    func canonicalJSONData(limits: IntentValueLimits = .default) throws -> Data {
        try validatedRepresentation(limits: limits).data
    }

    func canonicalSHA256Digest(limits: IntentValueLimits = .default) throws -> IntentDigest {
        let data = try canonicalJSONData(limits: limits)
        return IntentDigest(bytes: SHA256.hash(data: data))
    }
}

extension IntentValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            guard value.isFinite else {
                throw IntentValueError.nonFiniteNumber
            }
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([IntentValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: IntentValue].self) {
            self = .object(value)
        } else {
            throw IntentValueError.invalidJSON
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .number(value):
            guard value.isFinite else {
                throw IntentValueError.nonFiniteNumber
            }
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}

private extension IntentValue {
    struct TraversalState {
        var maximumDepth = 0
        var valueCount = 0
    }

    static func validate(_ limits: IntentValueLimits) throws {
        guard limits.maxEncodedBytes > 0,
              limits.maxEncodedBytes <= IntentValueLimits.hardMaximumEncodedBytes,
              limits.maxDepth > 0,
              limits.maxValueCount > 0,
              limits.maxCollectionCount >= 0,
              limits.maxStringBytes >= 0,
              limits.maxObjectKeyBytes >= 0
        else {
            throw IntentValueError.invalidLimits
        }
    }

    func validatedRepresentation(
        limits: IntentValueLimits
    ) throws -> (data: Data, accounting: IntentValueAccounting) {
        try Self.validate(limits)

        var state = TraversalState()
        try inspect(depth: 1, limits: limits, state: &state)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= limits.maxEncodedBytes else {
            throw IntentValueError.maximumEncodedBytesExceeded(limit: limits.maxEncodedBytes)
        }

        return (
            data,
            IntentValueAccounting(
                encodedBytes: data.count,
                maximumDepth: state.maximumDepth,
                valueCount: state.valueCount
            )
        )
    }

    func inspect(
        depth: Int,
        limits: IntentValueLimits,
        state: inout TraversalState
    ) throws {
        guard depth <= limits.maxDepth else {
            throw IntentValueError.maximumDepthExceeded(limit: limits.maxDepth)
        }

        state.maximumDepth = max(state.maximumDepth, depth)
        state.valueCount += 1
        guard state.valueCount <= limits.maxValueCount else {
            throw IntentValueError.maximumValueCountExceeded(limit: limits.maxValueCount)
        }

        switch self {
        case let .number(value):
            guard value.isFinite else {
                throw IntentValueError.nonFiniteNumber
            }

        case let .string(value):
            guard value.utf8.count <= limits.maxStringBytes else {
                throw IntentValueError.maximumStringBytesExceeded(limit: limits.maxStringBytes)
            }

        case let .array(values):
            guard values.count <= limits.maxCollectionCount else {
                throw IntentValueError.maximumCollectionCountExceeded(
                    limit: limits.maxCollectionCount
                )
            }
            for value in values {
                try value.inspect(depth: depth + 1, limits: limits, state: &state)
            }

        case let .object(values):
            guard values.count <= limits.maxCollectionCount else {
                throw IntentValueError.maximumCollectionCountExceeded(
                    limit: limits.maxCollectionCount
                )
            }
            for (key, value) in values {
                guard key.utf8.count <= limits.maxObjectKeyBytes else {
                    throw IntentValueError.maximumObjectKeyBytesExceeded(
                        limit: limits.maxObjectKeyBytes
                    )
                }
                try value.inspect(depth: depth + 1, limits: limits, state: &state)
            }

        case .null, .bool, .integer:
            break
        }
    }
}
