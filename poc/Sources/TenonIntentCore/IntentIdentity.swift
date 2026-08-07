// @domain: intent-bus
import Foundation

public struct IntentID: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String
    public let majorVersion: UInt

    public init(_ rawValue: String) throws {
        guard Self.isValidBaseName(rawValue, maximumLength: 128) else {
            throw IntentIdentityError.invalidIntentID(rawValue)
        }

        let version = rawValue.split(separator: ".", omittingEmptySubsequences: false).last ?? ""
        guard version.count >= 2,
              version.first == "v",
              version.dropFirst().first != "0",
              version.dropFirst().allSatisfy(\.isASCIIDigit),
              let majorVersion = UInt(version.dropFirst())
        else {
            throw IntentIdentityError.invalidIntentID(rawValue)
        }

        self.rawValue = rawValue
        self.majorVersion = majorVersion
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public typealias IntentName = IntentID

public struct PluginID: Sendable, Equatable, Hashable, Codable, CustomStringConvertible,
    ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard rawValue.split(
            separator: ".",
            omittingEmptySubsequences: false
        ).count >= 2,
            IntentID.isValidDNSName(rawValue)
        else {
            throw IntentIdentityError.invalidPluginID(rawValue)
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    /// String literals keep fixed, manifest-backed identities concise at call sites while
    /// still passing through the exact same validation as decoded or user-provided IDs.
    /// A malformed literal is a programmer error discovered as soon as that code executes.
    public init(stringLiteral value: String) {
        guard let pluginID = try? PluginID(value) else {
            preconditionFailure("invalid static plugin ID: \(value)")
        }
        self = pluginID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ProviderID: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard IntentID.isValidBaseName(rawValue, maximumLength: 128) else {
            throw IntentIdentityError.invalidProviderID(rawValue)
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct IntentDomainErrorCode: Sendable, Equatable, Hashable, Codable,
    CustomStringConvertible
{
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let components = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2,
              !rawValue.hasPrefix("tenon."),
              IntentID.isValidBaseName(rawValue, maximumLength: 128)
        else {
            throw IntentIdentityError.invalidDomainErrorCode(rawValue)
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum IntentIdentityError: Error, Sendable, Equatable {
    case invalidIntentID(String)
    case invalidPluginID(String)
    case invalidProviderID(String)
    case invalidDomainErrorCode(String)
}

private extension Character {
    var isASCIIDigit: Bool {
        unicodeScalars.count == 1 && unicodeScalars.first.map { (48 ... 57).contains($0.value) } == true
    }
}

extension IntentID {
    fileprivate static func isValidBaseName(_ value: String, maximumLength: Int) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= maximumLength,
              value.unicodeScalars.allSatisfy({
                  (97 ... 122).contains($0.value)
                      || (48 ... 57).contains($0.value)
                      || $0 == "."
                      || $0 == "-"
              })
        else {
            return false
        }

        return value
            .split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { segment in
                guard let first = segment.first, let last = segment.last else {
                    return false
                }
                return isASCIIAlphanumeric(first) && isASCIIAlphanumeric(last)
            }
    }

    fileprivate static func isValidDNSName(_ value: String) -> Bool {
        guard isValidBaseName(value, maximumLength: 253) else {
            return false
        }
        return value.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { $0.utf8.count <= 63 }
    }

    private static func isASCIIAlphanumeric(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value
        else {
            return false
        }
        return (97 ... 122).contains(value) || (48 ... 57).contains(value)
    }
}
