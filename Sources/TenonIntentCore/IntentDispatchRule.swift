// @domain: intent-bus
import Foundation

public struct IntentJSONPointer: Sendable, Equatable, Hashable, Codable,
    CustomStringConvertible
{
    public let rawValue: String
    fileprivate let tokens: [String]

    public init(_ rawValue: String) throws {
        guard rawValue.isEmpty || rawValue.first == "/" else {
            throw IntentDispatchRuleError.invalidJSONPointer(rawValue)
        }

        var decoded: [String] = []
        for component in rawValue.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).dropFirst() {
            var token = ""
            var index = component.startIndex
            while index < component.endIndex {
                let character = component[index]
                if character == "~" {
                    let next = component.index(after: index)
                    guard next < component.endIndex else {
                        throw IntentDispatchRuleError.invalidJSONPointer(rawValue)
                    }
                    switch component[next] {
                    case "0":
                        token.append("~")
                    case "1":
                        token.append("/")
                    default:
                        throw IntentDispatchRuleError.invalidJSONPointer(rawValue)
                    }
                    index = component.index(after: next)
                } else {
                    token.append(character)
                    index = component.index(after: index)
                }
            }
            decoded.append(token)
        }

        self.rawValue = rawValue
        self.tokens = decoded
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

    fileprivate func value(in root: IntentValue) throws -> IntentValue {
        var current = root
        for token in tokens {
            switch current {
            case let .object(values):
                guard let next = values[token] else {
                    throw IntentDispatchRuleError.missingPathValue(rawValue)
                }
                current = next
            case let .array(values):
                guard token == "0" || !token.hasPrefix("0"),
                      let index = Int(token),
                      values.indices.contains(index)
                else {
                    throw IntentDispatchRuleError.missingPathValue(rawValue)
                }
                current = values[index]
            default:
                throw IntentDispatchRuleError.missingPathValue(rawValue)
            }
        }
        return current
    }

    fileprivate func filesystemPaths(in root: IntentValue) throws -> [String] {
        switch try value(in: root) {
        case let .string(path):
            return [path]
        case let .array(values):
            return try values.map { value in
                guard case let .string(path) = value else {
                    throw IntentDispatchRuleError.pathValueIsNotString(rawValue)
                }
                return path
            }
        default:
            throw IntentDispatchRuleError.pathValueIsNotString(rawValue)
        }
    }

    fileprivate func networkHosts(in root: IntentValue) throws -> [String] {
        let rawURLs: [String]
        switch try value(in: root) {
        case let .string(url):
            rawURLs = [url]
        case let .array(values):
            rawURLs = try values.map { value in
                guard case let .string(url) = value else {
                    throw IntentDispatchRuleError.networkURLValueIsNotString(rawValue)
                }
                return url
            }
        default:
            throw IntentDispatchRuleError.networkURLValueIsNotString(rawValue)
        }

        return try rawURLs.map { rawURL in
            guard let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  url.user() == nil,
                  url.password() == nil,
                  url.port.map({ (0 ... 65_535).contains($0) }) ?? true,
                  let normalizedURL = URL(string: url.absoluteString),
                  let host = normalizedURL.host(),
                  let canonicalHost = NetworkHostPattern.canonicalHost(host)
            else {
                throw IntentDispatchRuleError.invalidNetworkURL(
                    pointer: rawValue,
                    value: rawURL
                )
            }
            return canonicalHost
        }
    }
}

public struct IntentCapabilityBinding: Sendable, Equatable, Hashable, Codable {
    public let capability: CapabilityID
    public let filesystemPathPointers: [IntentJSONPointer]
    public let networkURLPointers: [IntentJSONPointer]

    public init(
        capability: CapabilityID,
        filesystemPathPointers: [IntentJSONPointer] = [],
        networkURLPointers: [IntentJSONPointer] = []
    ) {
        self.capability = capability
        self.filesystemPathPointers = filesystemPathPointers
        self.networkURLPointers = networkURLPointers
    }

    fileprivate func requirement(input: IntentValue) throws -> CapabilityRequirement {
        var paths: [String] = []
        for pointer in filesystemPathPointers {
            paths.append(contentsOf: try pointer.filesystemPaths(in: input))
        }
        var networkHosts: [String] = []
        for pointer in networkURLPointers {
            networkHosts.append(contentsOf: try pointer.networkHosts(in: input))
        }
        return CapabilityRequirement(
            capability: capability,
            filesystemPaths: paths,
            networkHosts: networkHosts
        )
    }
}

public enum IntentProviderConsentPolicy: String, Sendable, Equatable, Hashable, Codable {
    case never
    case nonTrustedProvider
    case always
}

public struct IntentDispatchRule: Sendable, Equatable {
    public let intentID: IntentID
    public let capabilityBindings: [IntentCapabilityBinding]
    public let exposure: IntentExposure
    public let trustedDefault: ProviderID?
    public let allowsAutomaticSelection: Bool
    public let providerConsent: IntentProviderConsentPolicy
    public let admissionClass: IntentAdmissionClass
    public let valueLimits: IntentValueLimits
    public let maximumTimeout: Duration

    public init(
        intentID: IntentID,
        capabilityBindings: [IntentCapabilityBinding],
        exposure: IntentExposure,
        trustedDefault: ProviderID?,
        allowsAutomaticSelection: Bool,
        providerConsent: IntentProviderConsentPolicy,
        admissionClass: IntentAdmissionClass,
        valueLimits: IntentValueLimits = .default,
        maximumTimeout: Duration = .seconds(30)
    ) throws {
        guard maximumTimeout > .zero else {
            throw IntentDispatchRuleError.invalidMaximumTimeout
        }
        try IntentValue.object([:]).validate(limits: valueLimits)

        self.intentID = intentID
        self.capabilityBindings = capabilityBindings
        self.exposure = exposure
        self.trustedDefault = trustedDefault
        self.allowsAutomaticSelection = allowsAutomaticSelection
        self.providerConsent = providerConsent
        self.admissionClass = admissionClass
        self.valueLimits = valueLimits
        self.maximumTimeout = maximumTimeout
    }

    public func capabilityRequirements(input: IntentValue) throws -> [CapabilityRequirement] {
        try capabilityBindings.map { try $0.requirement(input: input) }
    }
}

public struct IntentDispatchRequest: Sendable, Equatable {
    public let intentID: IntentID
    public let input: IntentValue
    public let caller: IntentPrincipal
    public let scope: InvocationScope
    public let target: ProviderID?
    public let idempotencyKey: String?
    public let requestedTimeout: Duration?

    public init(
        intentID: IntentID,
        input: IntentValue,
        caller: IntentPrincipal,
        scope: InvocationScope = InvocationScope(),
        target: ProviderID? = nil,
        idempotencyKey: String? = nil,
        requestedTimeout: Duration? = nil
    ) {
        self.intentID = intentID
        self.input = input
        self.caller = caller
        self.scope = scope
        self.target = target
        self.idempotencyKey = idempotencyKey
        self.requestedTimeout = requestedTimeout
    }
}

public struct IntentDispatcherLimits: Sendable, Equatable {
    public let maxInFlightRequests: Int
    public let maxInFlightEncodedBytes: Int
    public let maxInFlightPerPrincipal: Int
    public let reservedInteractiveRequests: Int
    public let reservedInteractiveBytes: Int
    public let maximumTimeout: Duration
    public let maximumCausalDepth: Int
    public let progressMinimumInterval: Duration

    public init(
        maxInFlightRequests: Int = 512,
        maxInFlightEncodedBytes: Int = 32 * 1024 * 1024,
        maxInFlightPerPrincipal: Int = 64,
        reservedInteractiveRequests: Int = 32,
        reservedInteractiveBytes: Int = 2 * 1024 * 1024,
        maximumTimeout: Duration = .seconds(60),
        maximumCausalDepth: Int = 16,
        progressMinimumInterval: Duration = .milliseconds(50)
    ) throws {
        guard maxInFlightRequests > 0,
              maxInFlightEncodedBytes > 0,
              maxInFlightPerPrincipal > 0,
              reservedInteractiveRequests >= 0,
              (reservedInteractiveRequests < maxInFlightRequests),
              reservedInteractiveBytes >= 0,
              (reservedInteractiveBytes < maxInFlightEncodedBytes),
              (maximumTimeout > .zero),
              maximumCausalDepth > 0,
              progressMinimumInterval >= .zero
        else {
            throw IntentDispatchRuleError.invalidDispatcherLimits
        }
        self.maxInFlightRequests = maxInFlightRequests
        self.maxInFlightEncodedBytes = maxInFlightEncodedBytes
        self.maxInFlightPerPrincipal = maxInFlightPerPrincipal
        self.reservedInteractiveRequests = reservedInteractiveRequests
        self.reservedInteractiveBytes = reservedInteractiveBytes
        self.maximumTimeout = maximumTimeout
        self.maximumCausalDepth = maximumCausalDepth
        self.progressMinimumInterval = progressMinimumInterval
    }
}

public enum IntentDispatchRuleError: Error, Sendable, Equatable {
    case invalidJSONPointer(String)
    case missingPathValue(String)
    case pathValueIsNotString(String)
    case networkURLValueIsNotString(String)
    case invalidNetworkURL(pointer: String, value: String)
    case invalidMaximumTimeout
    case invalidDispatcherLimits
    case contractNotFound(IntentID)
    case exposureExceedsContractAudience(IntentAudience)
}
