import Darwin
import Foundation
import os

extension IntentAudience: Hashable {}

public struct CapabilityID: Sendable, Equatable, Hashable, Codable,
    CustomStringConvertible
{
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard Self.isValid(rawValue) else {
            throw IntentPolicyValidationError.invalidCapabilityID(rawValue)
        }
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 128,
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
                guard let first = segment.unicodeScalars.first,
                      let last = segment.unicodeScalars.last
                else {
                    return false
                }
                return Self.isASCIIAlphanumeric(first)
                    && Self.isASCIIAlphanumeric(last)
            }
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (97 ... 122).contains(scalar.value) || (48 ... 57).contains(scalar.value)
    }
}

public enum IntentPolicyValidationError: Error, Sendable, Equatable {
    case invalidCapabilityID(String)
    case invalidFilesystemRoot(String)
    case invalidNetworkHostPattern(String)
}

public enum PolicyEngineError: Error, Sendable, Equatable {
    case revisionExhausted
}

public enum AuthorizedFilesystemPathError: Error, Sendable, Equatable {
    case unavailable
    case becameSymlink
}

/// A filesystem location resolved and pinned while policy authorization is evaluated.
///
/// The parent directory descriptor is immutable for the lifetime of this value. Providers
/// duplicate it and perform descriptor-relative operations, so replacing an intermediate
/// symlink after authorization cannot redirect the operation. Final-component symlinks are
/// rejected when the binding is created.
public struct AuthorizedFilesystemPath: @unchecked Sendable, Equatable, Hashable {
    public let requestedPath: String
    public let resolvedPath: String
    public let leafName: String
    public let existedAtAuthorization: Bool

    private let parentDirectory: AuthorizedFilesystemDirectory

    init(requestedPath: String) throws {
        guard !requestedPath.isEmpty,
              !requestedPath.utf8.contains(0),
              (requestedPath as NSString).isAbsolutePath
        else {
            throw IntentPolicyValidationError.invalidFilesystemRoot(requestedPath)
        }

        let standardized = URL(fileURLWithPath: requestedPath).standardizedFileURL.path
        let path = standardized as NSString
        let parentPath = path.deletingLastPathComponent.isEmpty
            ? "/"
            : path.deletingLastPathComponent
        let leafName = path.lastPathComponent.isEmpty ? "." : path.lastPathComponent

        let resolvedParentPath = URL(fileURLWithPath: parentPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let descriptor = Darwin.open(
            resolvedParentPath,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw IntentPolicyValidationError.invalidFilesystemRoot(requestedPath)
        }
        let parentDirectory = AuthorizedFilesystemDirectory(
            descriptor: descriptor,
            resolvedPath: resolvedParentPath
        )

        var descriptorMetadata = stat()
        var pathMetadata = stat()
        guard fstat(descriptor, &descriptorMetadata) == 0,
              Darwin.lstat(resolvedParentPath, &pathMetadata) == 0,
              descriptorMetadata.st_dev == pathMetadata.st_dev,
              descriptorMetadata.st_ino == pathMetadata.st_ino
        else {
            throw IntentPolicyValidationError.invalidFilesystemRoot(requestedPath)
        }

        var metadata = stat()
        let status = leafName.withCString {
            fstatat(descriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        let existed: Bool
        if status == 0 {
            guard (metadata.st_mode & S_IFMT) != S_IFLNK else {
                throw IntentPolicyValidationError.invalidFilesystemRoot(requestedPath)
            }
            existed = true
        } else {
            guard errno == ENOENT else {
                throw IntentPolicyValidationError.invalidFilesystemRoot(requestedPath)
            }
            existed = false
        }

        self.requestedPath = requestedPath
        self.resolvedPath = URL(
            fileURLWithPath: resolvedParentPath,
            isDirectory: true
        )
        .appendingPathComponent(leafName)
        .standardizedFileURL
        .path
        self.leafName = leafName
        self.existedAtAuthorization = existed
        self.parentDirectory = parentDirectory
    }

    /// Returns an owned duplicate. The caller must close it.
    public func duplicateParentDirectoryDescriptor() throws -> Int32 {
        try parentDirectory.duplicateDescriptor()
    }

    /// Revalidates the final directory entry relative to the pinned parent descriptor.
    ///
    /// The returned path is the authorization-time canonical spelling; callers must never
    /// reconstruct a URL from `requestedPath`.
    public func validatedResolvedPath() throws -> String {
        let parent = try duplicateParentDirectoryDescriptor()
        defer { Darwin.close(parent) }
        var metadata = stat()
        let status = leafName.withCString {
            fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else {
            throw AuthorizedFilesystemPathError.unavailable
        }
        guard (metadata.st_mode & S_IFMT) != S_IFLNK else {
            throw AuthorizedFilesystemPathError.becameSymlink
        }
        return resolvedPath
    }

    public static func == (
        lhs: AuthorizedFilesystemPath,
        rhs: AuthorizedFilesystemPath
    ) -> Bool {
        lhs.requestedPath == rhs.requestedPath
            && lhs.resolvedPath == rhs.resolvedPath
            && lhs.leafName == rhs.leafName
            && lhs.existedAtAuthorization == rhs.existedAtAuthorization
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(requestedPath)
        hasher.combine(resolvedPath)
        hasher.combine(leafName)
        hasher.combine(existedAtAuthorization)
    }
}

public struct AuthorizedNetworkHost: Sendable, Equatable, Hashable {
    public let requestedHost: String
    public let canonicalHost: String
    public let allowsPrivateEndpoints: Bool

    init(
        requestedHost: String,
        canonicalHost: String,
        allowsPrivateEndpoints: Bool
    ) {
        self.requestedHost = requestedHost
        self.canonicalHost = canonicalHost
        self.allowsPrivateEndpoints = allowsPrivateEndpoints
    }
}

private final class AuthorizedFilesystemDirectory: @unchecked Sendable {
    private let descriptor: Int32
    let resolvedPath: String

    init(descriptor: Int32, resolvedPath: String) {
        self.descriptor = descriptor
        self.resolvedPath = resolvedPath
    }

    deinit {
        Darwin.close(descriptor)
    }

    func duplicateDescriptor() throws -> Int32 {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return duplicate
    }
}

public struct CanonicalFilesystemRoot: Sendable, Equatable, Hashable, Codable {
    public let path: String

    public init(path: String) throws {
        guard let canonicalPath = Self.canonicalPath(path) else {
            throw IntentPolicyValidationError.invalidFilesystemRoot(path)
        }
        self.path = canonicalPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(path: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(path)
    }

    fileprivate func contains(_ candidatePath: String) -> Bool {
        if path == "/" {
            return true
        }
        return candidatePath == path || candidatePath.hasPrefix(path + "/")
    }

    fileprivate static func canonicalPath(_ rawPath: String) -> String? {
        guard !rawPath.isEmpty,
              !rawPath.utf8.contains(0),
              (rawPath as NSString).isAbsolutePath
        else {
            return nil
        }

        let resolved = URL(fileURLWithPath: rawPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        guard !resolved.isEmpty, (resolved as NSString).isAbsolutePath else {
            return nil
        }
        return resolved
    }
}

public enum PolicyEntityScope: Sendable, Equatable, Hashable, Codable {
    case any
    case only(Set<UUID>)
}

public enum FilesystemGrantScope: Sendable, Equatable, Hashable, Codable {
    case none
    case all
    case roots(Set<CanonicalFilesystemRoot>)
}

public struct NetworkHostPattern: Sendable, Equatable, Hashable, Codable,
    CustomStringConvertible
{
    public let rawValue: String
    private let host: String
    private let matchesSubdomainsOnly: Bool

    public init(_ rawValue: String) throws {
        let lowered = rawValue.lowercased()
        let matchesSubdomainsOnly = lowered.hasPrefix("*.")
        let requestedHost = matchesSubdomainsOnly
            ? String(lowered.dropFirst(2))
            : lowered
        guard let host = Self.canonicalHost(requestedHost),
              !matchesSubdomainsOnly || (
                  Self.isValidDNSHost(host)
                      && host.split(separator: ".").count >= 2
              )
        else {
            throw IntentPolicyValidationError.invalidNetworkHostPattern(rawValue)
        }
        self.rawValue = matchesSubdomainsOnly ? "*.\(host)" : host
        self.host = host
        self.matchesSubdomainsOnly = matchesSubdomainsOnly
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

    fileprivate func contains(_ candidate: String) -> Bool {
        guard let candidate = Self.canonicalHost(candidate) else {
            return false
        }
        return matchesSubdomainsOnly
            ? candidate.hasSuffix("." + host)
            : candidate == host
    }

    static func canonicalHost(_ rawHost: String) -> String? {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        if let address = canonicalIPAddress(host) {
            return address
        }
        if host.hasSuffix(".") {
            host.removeLast()
        }
        return isValidDNSHost(host) ? host : nil
    }

    fileprivate static func isIPAddress(_ host: String) -> Bool {
        canonicalIPAddress(host) != nil
    }

    private static func isValidDNSHost(_ host: String) -> Bool {
        guard !host.isEmpty,
              host.utf8.count <= 253,
              host.unicodeScalars.allSatisfy({
                  (97 ... 122).contains($0.value)
                      || (48 ... 57).contains($0.value)
                      || $0 == "."
                      || $0 == "-"
              })
        else {
            return false
        }
        return host.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { label in
                guard !label.isEmpty,
                      label.utf8.count <= 63,
                      let first = label.unicodeScalars.first,
                      let last = label.unicodeScalars.last
                else {
                    return false
                }
                return first != "-" && last != "-"
            }
    }

    private static func canonicalIPAddress(_ host: String) -> String? {
        if let ipv4 = canonicalIPAddress(
            host,
            family: AF_INET,
            addressByteCount: MemoryLayout<in_addr>.size,
            textCapacity: Int(INET_ADDRSTRLEN)
        ) {
            return ipv4
        }
        return canonicalIPAddress(
            host,
            family: AF_INET6,
            addressByteCount: MemoryLayout<in6_addr>.size,
            textCapacity: Int(INET6_ADDRSTRLEN)
        )
    }

    private static func canonicalIPAddress(
        _ host: String,
        family: Int32,
        addressByteCount: Int,
        textCapacity: Int
    ) -> String? {
        var address = [UInt8](repeating: 0, count: addressByteCount)
        let parsed = address.withUnsafeMutableBytes { addressBuffer in
            host.withCString { source in
                inet_pton(family, source, addressBuffer.baseAddress)
            }
        }
        guard parsed == 1 else {
            return nil
        }

        var text = [CChar](repeating: 0, count: textCapacity)
        let rendered = address.withUnsafeBytes { addressBuffer in
            text.withUnsafeMutableBufferPointer { textBuffer in
                inet_ntop(
                    family,
                    addressBuffer.baseAddress,
                    textBuffer.baseAddress,
                    socklen_t(textBuffer.count)
                )
            }
        }
        guard rendered != nil else {
            return nil
        }
        return String(
            decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }
}

public enum NetworkGrantScope: Sendable, Equatable, Hashable, Codable {
    case none
    case all
    case hosts(Set<NetworkHostPattern>)
}

public struct CapabilityGrantScope: Sendable, Equatable, Hashable, Codable {
    public let workspaces: PolicyEntityScope
    public let panes: PolicyEntityScope
    public let filesystem: FilesystemGrantScope
    public let network: NetworkGrantScope

    public init(
        workspaces: PolicyEntityScope,
        panes: PolicyEntityScope,
        filesystem: FilesystemGrantScope,
        network: NetworkGrantScope = .none
    ) {
        self.workspaces = workspaces
        self.panes = panes
        self.filesystem = filesystem
        self.network = network
    }
}

public struct CapabilityGrant: Sendable, Equatable, Hashable, Codable {
    public let capability: CapabilityID
    public let scope: CapabilityGrantScope

    public init(capability: CapabilityID, scope: CapabilityGrantScope) {
        self.capability = capability
        self.scope = scope
    }
}

public struct CapabilityRequirement: Sendable, Equatable, Hashable, Codable {
    public let capability: CapabilityID
    public let filesystemPaths: [String]
    public let networkHosts: [String]

    public init(
        capability: CapabilityID,
        filesystemPaths: [String] = [],
        networkHosts: [String] = []
    ) {
        self.capability = capability
        self.filesystemPaths = filesystemPaths
        self.networkHosts = networkHosts
    }
}

public struct IntentExposure: Sendable, Equatable, Hashable, Codable {
    public let discoverableBy: Set<IntentAudience>
    public let invocableBy: Set<IntentAudience>

    public init(
        discoverableBy: Set<IntentAudience>,
        invocableBy: Set<IntentAudience>
    ) {
        self.discoverableBy = discoverableBy
        self.invocableBy = invocableBy
    }
}

public struct PolicyRevision: Sendable, Equatable, Hashable, Codable, Comparable {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: PolicyRevision, rhs: PolicyRevision) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct PolicyFingerprint: Sendable, Equatable, Hashable, Codable,
    CustomStringConvertible
{
    public let hex: String

    public init(canonicalPolicy: IntentValue) throws {
        hex = try canonicalPolicy.canonicalSHA256Digest().hex
    }

    public var description: String {
        hex
    }
}

public struct ProviderConsentKey: Sendable, Equatable, Hashable, Codable {
    public let contract: IntentID
    public let providerID: ProviderID
    public let policyFingerprint: PolicyFingerprint

    public init(
        contract: IntentID,
        providerID: ProviderID,
        policyFingerprint: PolicyFingerprint
    ) {
        self.contract = contract
        self.providerID = providerID
        self.policyFingerprint = policyFingerprint
    }
}

public enum ProviderConsentDecision: String, Sendable, Equatable, Hashable, Codable {
    case allow
    case deny
}

public enum ProviderConsentRequirement: Sendable, Equatable, Hashable, Codable {
    case notRequired
    case required(ProviderConsentKey)
}

/// One caller installation's standing approval for a `.policy` contract.
///
/// The key deliberately omits `sessionRevision`: consent belongs to an installation, not
/// to a runtime generation, so hot reload does not re-ask. Runtime retirement removes the
/// exact generation's authority; installation withdrawal explicitly revokes this stable key.
public struct CallerConsentKey: Sendable, Equatable, Hashable, Codable {
    public let callerID: String
    public let callerKind: IntentPrincipal.Kind
    public let contract: IntentID

    public init(caller: IntentPrincipal, contract: IntentID) {
        callerID = caller.id
        callerKind = caller.kind
        self.contract = contract
    }
}

final class CallerConsentGrantFence: Sendable {
    private let isValid = OSAllocatedUnfairLock(initialState: true)

    func invalidate() {
        isValid.withLock { $0 = false }
    }

    func performIfValid(
        _ operation: () throws -> Void
    ) rethrows -> Bool {
        // SAFETY: This lock body and the actor-isolated operation execute immediately
        // and synchronously; neither closure escapes. Holding the lock across the
        // operation keeps it atomic with invalidate().
        try isValid.withLockUnchecked { isValid in
            guard isValid else {
                return false
            }
            try operation()
            return true
        }
    }
}

public enum CallerConsentRequirement: Sendable, Equatable, Hashable, Codable {
    case notRequired
    case required(CallerConsentKey)
}

public struct PolicyDiscoveryRequest: Sendable, Equatable {
    public let intent: IntentID
    public let caller: IntentPrincipal
    public let requiredCapabilities: Set<CapabilityID>

    public init(
        intent: IntentID,
        caller: IntentPrincipal,
        requiredCapabilities: Set<CapabilityID>
    ) {
        self.intent = intent
        self.caller = caller
        self.requiredCapabilities = requiredCapabilities
    }
}

public struct PolicyInvocationRequest: Sendable, Equatable {
    public let envelope: IntentEnvelope
    public let capabilityRequirements: [CapabilityRequirement]
    public let providerConsent: ProviderConsentRequirement
    public let callerConsent: CallerConsentRequirement

    public init(
        envelope: IntentEnvelope,
        capabilityRequirements: [CapabilityRequirement],
        providerConsent: ProviderConsentRequirement,
        callerConsent: CallerConsentRequirement = .notRequired
    ) {
        self.envelope = envelope
        self.capabilityRequirements = capabilityRequirements
        self.providerConsent = providerConsent
        self.callerConsent = callerConsent
    }
}

public enum PolicyDenialReason: Sendable, Equatable, Hashable {
    case undeclaredUse(IntentID)
    case intentNotDiscoverable(intent: IntentID, audience: IntentAudience)
    case audienceCannotInvoke(intent: IntentID, audience: IntentAudience)
    case missingCapability(CapabilityID)
    case workspaceRequired(CapabilityID)
    case workspaceOutsideGrant(capability: CapabilityID, workspaceID: UUID)
    case paneRequired(CapabilityID)
    case paneOutsideGrant(capability: CapabilityID, paneID: UUID)
    case invalidFilesystemPath(capability: CapabilityID, path: String)
    case filesystemPathOutsideGrant(capability: CapabilityID, path: String)
    case invalidNetworkHost(capability: CapabilityID, host: String)
    case networkHostOutsideGrant(capability: CapabilityID, host: String)
    case providerConsentContractMismatch(expected: IntentID, provided: IntentID)
    case providerConsentProviderMismatch(expected: ProviderID, provided: ProviderID)
    case providerConsentRequired(ProviderConsentKey)
    case providerConsentDenied(ProviderConsentKey)
    case providerConsentStale(
        contract: IntentID,
        providerID: ProviderID,
        consentedFingerprint: PolicyFingerprint,
        currentFingerprint: PolicyFingerprint
    )
    case callerConsentContractMismatch(expected: IntentID, provided: IntentID)
    case callerConsentCallerMismatch(
        expectedID: String,
        expectedKind: IntentPrincipal.Kind,
        providedID: String,
        providedKind: IntentPrincipal.Kind
    )
    case callerConsentRequired(CallerConsentKey)
}

public enum PolicyVerdict: Sendable, Equatable, Hashable {
    case allowed
    case denied(PolicyDenialReason)
}

public struct PolicyDecision: Sendable, Equatable, Hashable {
    public let verdict: PolicyVerdict
    public let policyRevision: PolicyRevision
    public let authorizedFilesystemPaths: [AuthorizedFilesystemPath]
    public let authorizedNetworkHosts: [AuthorizedNetworkHost]

    public init(
        verdict: PolicyVerdict,
        policyRevision: PolicyRevision,
        authorizedFilesystemPaths: [AuthorizedFilesystemPath] = [],
        authorizedNetworkHosts: [AuthorizedNetworkHost] = []
    ) {
        self.verdict = verdict
        self.policyRevision = policyRevision
        self.authorizedFilesystemPaths = authorizedFilesystemPaths
        self.authorizedNetworkHosts = authorizedNetworkHosts
    }
}

public struct PolicySnapshot: Sendable, Equatable {
    public let revision: PolicyRevision
    public let declaredUses: [IntentPrincipal: Set<IntentID>]
    public let grants: [IntentPrincipal: Set<CapabilityGrant>]
    public let exposures: [IntentID: IntentExposure]
    public let providerConsents: [ProviderConsentKey: ProviderConsentDecision]
    public let callerConsents: Set<CallerConsentKey>

    public init(
        revision: PolicyRevision,
        declaredUses: [IntentPrincipal: Set<IntentID>],
        grants: [IntentPrincipal: Set<CapabilityGrant>],
        exposures: [IntentID: IntentExposure],
        providerConsents: [ProviderConsentKey: ProviderConsentDecision],
        callerConsents: Set<CallerConsentKey> = []
    ) {
        self.revision = revision
        self.declaredUses = declaredUses
        self.grants = grants
        self.exposures = exposures
        self.providerConsents = providerConsents
        self.callerConsents = callerConsents
    }
}

public actor PolicyEngine {
    private typealias RevisionWaiter = CheckedContinuation<PolicyRevision, any Error>

    private var revisionValue: UInt64 = 0
    private var declaredUsesByPrincipal: [IntentPrincipal: Set<IntentID>] = [:]
    private var grantsByPrincipal: [IntentPrincipal: Set<CapabilityGrant>] = [:]
    private var exposuresByIntent: [IntentID: IntentExposure] = [:]
    private var providerConsentDecisions: [ProviderConsentKey: ProviderConsentDecision] = [:]
    private var standingCallerConsents: Set<CallerConsentKey> = []
    private var revisionWaiters: [UUID: RevisionWaiter] = [:]

    public init() {}

    init(initialRevisionForTesting: UInt64) {
        revisionValue = initialRevisionForTesting
    }

    public func snapshot() -> PolicySnapshot {
        PolicySnapshot(
            revision: currentRevision,
            declaredUses: declaredUsesByPrincipal,
            grants: grantsByPrincipal,
            exposures: exposuresByIntent,
            providerConsents: providerConsentDecisions,
            callerConsents: standingCallerConsents
        )
    }

    /// Suspends without polling until policy state differs from `revision`.
    public func waitForRevision(after revision: PolicyRevision) async throws -> PolicyRevision {
        try Task.checkCancellation()
        guard revision == currentRevision else {
            return currentRevision
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                revisionWaiters[waiterID] = continuation
                if Task.isCancelled {
                    cancelRevisionWaiter(waiterID)
                }
            }
        } onCancel: {
            Task { [engine = self] in
                await engine.cancelRevisionWaiter(waiterID)
            }
        }
    }

    public func setExposure(
        _ exposure: IntentExposure,
        for intent: IntentID
    ) throws {
        guard exposuresByIntent[intent] != exposure else {
            return
        }
        try prepareRevisionAdvance()
        exposuresByIntent[intent] = exposure
        commitRevisionAdvance()
    }

    public func removeExposure(for intent: IntentID) throws {
        guard exposuresByIntent[intent] != nil else {
            return
        }
        try prepareRevisionAdvance()
        exposuresByIntent.removeValue(forKey: intent)
        commitRevisionAdvance()
    }

    public func replaceDeclaredUses(
        _ uses: Set<IntentID>,
        for principal: IntentPrincipal
    ) throws {
        if uses.isEmpty {
            guard declaredUsesByPrincipal[principal] != nil else {
                return
            }
            try prepareRevisionAdvance()
            declaredUsesByPrincipal.removeValue(forKey: principal)
            commitRevisionAdvance()
        } else {
            guard declaredUsesByPrincipal[principal] != uses else {
                return
            }
            try prepareRevisionAdvance()
            declaredUsesByPrincipal[principal] = uses
            commitRevisionAdvance()
        }
    }

    public func replaceGrants(
        _ grants: Set<CapabilityGrant>,
        for principal: IntentPrincipal
    ) throws {
        if grants.isEmpty {
            guard grantsByPrincipal[principal] != nil else {
                return
            }
            try prepareRevisionAdvance()
            grantsByPrincipal.removeValue(forKey: principal)
            commitRevisionAdvance()
        } else {
            guard grantsByPrincipal[principal] != grants else {
                return
            }
            try prepareRevisionAdvance()
            grantsByPrincipal[principal] = grants
            commitRevisionAdvance()
        }
    }

    /// Retires one runtime generation's authority.
    ///
    /// Standing consent deliberately survives this. Hot reload activates the replacement
    /// generation and only then retires the previous one, and both share a caller id — so
    /// clearing consent here would revoke what the live generation just established.
    /// Withdrawing a plugin is a separate act with its own call, `revokeStandingConsents`.
    public func removePrincipal(_ principal: IntentPrincipal) throws {
        guard declaredUsesByPrincipal[principal] != nil
            || grantsByPrincipal[principal] != nil
        else {
            return
        }
        try prepareRevisionAdvance()
        declaredUsesByPrincipal[principal] = nil
        grantsByPrincipal[principal] = nil
        commitRevisionAdvance()
    }

    /// Grants one caller standing consent for a `.policy` contract.
    ///
    /// Allow-only by construction: the confirmation dialog calls this after the user
    /// approves, and the host calls it to seed plugins the user accepted by installing the
    /// app. A modal denial is wave-local and must stay recoverable, so it has no way in
    /// here. Consent is never authority on its own — a granted contract still clears
    /// declared use, audience, capability, and scope on every single invocation.
    public func grantStandingConsent(
        contract: IntentID,
        caller: IntentPrincipal
    ) throws {
        let key = CallerConsentKey(caller: caller, contract: contract)
        guard !standingCallerConsents.contains(key) else {
            return
        }
        try prepareRevisionAdvance()
        standingCallerConsents.insert(key)
        commitRevisionAdvance()
    }

    func grantStandingConsent(
        for key: CallerConsentKey,
        guardedBy fence: CallerConsentGrantFence
    ) throws -> Bool {
        try fence.performIfValid {
            guard !standingCallerConsents.contains(key) else {
                return
            }
            try prepareRevisionAdvance()
            standingCallerConsents.insert(key)
            commitRevisionAdvance()
        }
    }

    public func hasStandingConsent(
        contract: IntentID,
        caller: IntentPrincipal
    ) -> Bool {
        standingCallerConsents.contains(
            CallerConsentKey(caller: caller, contract: contract)
        )
    }

    public func revokeStandingConsent(
        contract: IntentID,
        caller: IntentPrincipal
    ) throws {
        let key = CallerConsentKey(caller: caller, contract: contract)
        guard standingCallerConsents.contains(key) else {
            return
        }
        try prepareRevisionAdvance()
        standingCallerConsents.remove(key)
        commitRevisionAdvance()
    }

    /// Drops every standing consent held by one caller identity.
    ///
    /// This is withdrawal — the user disabling or uninstalling a plugin — not generation
    /// turnover. It matches on the stable caller identity, so it takes the consents of
    /// every generation of that installation.
    public func revokeStandingConsents(for principal: IntentPrincipal) throws {
        let revoked = standingCallerConsents.filter {
            $0.callerID == principal.id
                && $0.callerKind == principal.kind
        }
        guard !revoked.isEmpty else {
            return
        }
        try prepareRevisionAdvance()
        standingCallerConsents.subtract(revoked)
        commitRevisionAdvance()
    }

    public func recordProviderConsent(
        _ decision: ProviderConsentDecision,
        for key: ProviderConsentKey
    ) throws {
        var replacement = providerConsentDecisions
        replacement = replacement.filter {
            !Self.hasSameConsentSubject($0.key, key) || $0.key == key
        }
        replacement[key] = decision
        guard replacement != providerConsentDecisions else {
            return
        }
        try prepareRevisionAdvance()
        providerConsentDecisions = replacement
        commitRevisionAdvance()
    }

    public func revokeProviderConsent(for key: ProviderConsentKey) throws {
        guard providerConsentDecisions[key] != nil else {
            return
        }
        try prepareRevisionAdvance()
        providerConsentDecisions.removeValue(forKey: key)
        commitRevisionAdvance()
    }

    public func discover(_ request: PolicyDiscoveryRequest) -> PolicyDecision {
        if let denial = declaredUseDenial(
            intent: request.intent,
            caller: request.caller
        ) {
            return denied(denial)
        }

        guard exposuresByIntent[request.intent]?.discoverableBy
            .contains(request.caller.audience) == true
        else {
            return denied(
                .intentNotDiscoverable(
                    intent: request.intent,
                    audience: request.caller.audience
                )
            )
        }

        let callerCapabilities = Set(
            (grantsByPrincipal[request.caller] ?? []).map(\.capability)
        )
        for capability in request.requiredCapabilities.sorted(by: {
            $0.rawValue < $1.rawValue
        }) where !callerCapabilities.contains(capability) {
            return denied(.missingCapability(capability))
        }

        return allowed()
    }

    public func authorize(_ request: PolicyInvocationRequest) -> PolicyDecision {
        let envelope = request.envelope
        if let denial = declaredUseDenial(intent: envelope.name, caller: envelope.caller) {
            return denied(denial)
        }

        guard exposuresByIntent[envelope.name]?.invocableBy
            .contains(envelope.caller.audience) == true
        else {
            return denied(
                .audienceCannotInvoke(
                    intent: envelope.name,
                    audience: envelope.caller.audience
                )
            )
        }

        let orderedRequirements = request.capabilityRequirements.sorted {
            if $0.capability.rawValue == $1.capability.rawValue {
                if $0.filesystemPaths == $1.filesystemPaths {
                    return $0.networkHosts.lexicographicallyPrecedes($1.networkHosts)
                }
                return $0.filesystemPaths.lexicographicallyPrecedes($1.filesystemPaths)
            }
            return $0.capability.rawValue < $1.capability.rawValue
        }
        var authorizedFilesystemPaths: [String: AuthorizedFilesystemPath] = [:]
        var authorizedNetworkHosts: [String: AuthorizedNetworkHost] = [:]
        for requirement in orderedRequirements {
            if let denial = capabilityDenial(
                requirement,
                caller: envelope.caller,
                invocationScope: envelope.scope,
                authorizedFilesystemPaths: &authorizedFilesystemPaths,
                authorizedNetworkHosts: &authorizedNetworkHosts
            ) {
                return denied(denial)
            }
        }

        switch request.providerConsent {
        case .notRequired:
            break
        case let .required(key):
            guard key.contract == envelope.name else {
                return denied(
                    .providerConsentContractMismatch(
                        expected: envelope.name,
                        provided: key.contract
                    )
                )
            }
            if let target = envelope.target, target != key.providerID {
                return denied(
                    .providerConsentProviderMismatch(
                        expected: target,
                        provided: key.providerID
                    )
                )
            }

            switch providerConsentDecisions[key] {
            case .allow:
                break
            case .deny:
                return denied(.providerConsentDenied(key))
            case nil:
                let staleKeys = providerConsentDecisions.keys
                    .filter { Self.hasSameConsentSubject($0, key) }
                    .sorted { $0.policyFingerprint.hex < $1.policyFingerprint.hex }
                guard let staleKey = staleKeys.first else {
                    return denied(.providerConsentRequired(key))
                }

                return denied(
                    .providerConsentStale(
                        contract: key.contract,
                        providerID: key.providerID,
                        consentedFingerprint: staleKey.policyFingerprint,
                        currentFingerprint: key.policyFingerprint
                    )
                )
            }
        }

        switch request.callerConsent {
        case .notRequired:
            break
        case let .required(key):
            guard key.contract == envelope.name else {
                return denied(
                    .callerConsentContractMismatch(
                        expected: envelope.name,
                        provided: key.contract
                    )
                )
            }
            guard key.callerID == envelope.caller.id,
                  key.callerKind == envelope.caller.kind
            else {
                return denied(
                    .callerConsentCallerMismatch(
                        expectedID: envelope.caller.id,
                        expectedKind: envelope.caller.kind,
                        providedID: key.callerID,
                        providedKind: key.callerKind
                    )
                )
            }
            guard standingCallerConsents.contains(key) else {
                return denied(.callerConsentRequired(key))
            }
        }

        return allowed(
            authorizedFilesystemPaths: Array(authorizedFilesystemPaths.values),
            authorizedNetworkHosts: Array(authorizedNetworkHosts.values)
        )
    }

    private var currentRevision: PolicyRevision {
        PolicyRevision(revisionValue)
    }

    private func declaredUseDenial(
        intent: IntentID,
        caller: IntentPrincipal
    ) -> PolicyDenialReason? {
        guard caller.kind == .plugin else {
            return nil
        }
        guard declaredUsesByPrincipal[caller]?.contains(intent) == true else {
            return .undeclaredUse(intent)
        }
        return nil
    }

    private func capabilityDenial(
        _ requirement: CapabilityRequirement,
        caller: IntentPrincipal,
        invocationScope: InvocationScope,
        authorizedFilesystemPaths: inout [String: AuthorizedFilesystemPath],
        authorizedNetworkHosts: inout [String: AuthorizedNetworkHost]
    ) -> PolicyDenialReason? {
        var candidates = Array(
            (grantsByPrincipal[caller] ?? [])
                .filter { $0.capability == requirement.capability }
        )
        guard !candidates.isEmpty else {
            return .missingCapability(requirement.capability)
        }

        var boundPaths: [AuthorizedFilesystemPath] = []
        for path in requirement.filesystemPaths {
            if let existing = authorizedFilesystemPaths[path] {
                boundPaths.append(existing)
                continue
            }
            do {
                let binding = try AuthorizedFilesystemPath(requestedPath: path)
                authorizedFilesystemPaths[path] = binding
                boundPaths.append(binding)
            } catch {
                return .invalidFilesystemPath(
                    capability: requirement.capability,
                    path: path
                )
            }
        }

        candidates = candidates.filter {
            Self.matches($0.scope.workspaces, entityID: invocationScope.workspaceID)
        }
        if candidates.isEmpty {
            guard let workspaceID = invocationScope.workspaceID else {
                return .workspaceRequired(requirement.capability)
            }
            return .workspaceOutsideGrant(
                capability: requirement.capability,
                workspaceID: workspaceID
            )
        }

        candidates = candidates.filter {
            Self.matches($0.scope.panes, entityID: invocationScope.paneID)
        }
        if candidates.isEmpty {
            guard let paneID = invocationScope.paneID else {
                return .paneRequired(requirement.capability)
            }
            return .paneOutsideGrant(
                capability: requirement.capability,
                paneID: paneID
            )
        }

        for path in boundPaths {
            candidates = candidates.filter {
                Self.matches(
                    $0.scope.filesystem,
                    canonicalPath: path.resolvedPath
                )
            }
            if candidates.isEmpty {
                return .filesystemPathOutsideGrant(
                    capability: requirement.capability,
                    path: path.requestedPath
                )
            }
        }

        for host in requirement.networkHosts {
            guard let canonicalHost = NetworkHostPattern.canonicalHost(host) else {
                return .invalidNetworkHost(
                    capability: requirement.capability,
                    host: host
                )
            }
            candidates = candidates.filter {
                Self.matches($0.scope.network, canonicalHost: canonicalHost)
            }
            if candidates.isEmpty {
                return .networkHostOutsideGrant(
                    capability: requirement.capability,
                    host: host
                )
            }
            let allowsPrivateEndpoints = candidates.contains { candidate in
                switch candidate.scope.network {
                case .all:
                    true
                case let .hosts(patterns):
                    NetworkHostPattern.isIPAddress(canonicalHost)
                        && patterns.contains {
                            $0.rawValue == canonicalHost
                        }
                case .none:
                    false
                }
            }
            authorizedNetworkHosts[host] = AuthorizedNetworkHost(
                requestedHost: host,
                canonicalHost: canonicalHost,
                allowsPrivateEndpoints: allowsPrivateEndpoints
            )
        }

        return nil
    }

    private static func matches(_ scope: PolicyEntityScope, entityID: UUID?) -> Bool {
        switch scope {
        case .any:
            true
        case let .only(ids):
            entityID.map(ids.contains) ?? false
        }
    }

    private static func matches(
        _ scope: FilesystemGrantScope,
        canonicalPath: String
    ) -> Bool {
        switch scope {
        case .none:
            false
        case .all:
            true
        case let .roots(roots):
            roots.contains { $0.contains(canonicalPath) }
        }
    }

    private static func matches(
        _ scope: NetworkGrantScope,
        canonicalHost: String
    ) -> Bool {
        switch scope {
        case .none:
            false
        case .all:
            true
        case let .hosts(patterns):
            patterns.contains { $0.contains(canonicalHost) }
        }
    }

    private static func hasSameConsentSubject(
        _ lhs: ProviderConsentKey,
        _ rhs: ProviderConsentKey
    ) -> Bool {
        lhs.contract == rhs.contract && lhs.providerID == rhs.providerID
    }

    private func allowed(
        authorizedFilesystemPaths: [AuthorizedFilesystemPath] = [],
        authorizedNetworkHosts: [AuthorizedNetworkHost] = []
    ) -> PolicyDecision {
        PolicyDecision(
            verdict: .allowed,
            policyRevision: currentRevision,
            authorizedFilesystemPaths: authorizedFilesystemPaths.sorted {
                $0.requestedPath < $1.requestedPath
            },
            authorizedNetworkHosts: authorizedNetworkHosts.sorted {
                $0.requestedHost < $1.requestedHost
            }
        )
    }

    private func denied(_ reason: PolicyDenialReason) -> PolicyDecision {
        PolicyDecision(verdict: .denied(reason), policyRevision: currentRevision)
    }

    private func prepareRevisionAdvance() throws {
        guard revisionValue < UInt64.max else {
            throw PolicyEngineError.revisionExhausted
        }
    }

    private func commitRevisionAdvance() {
        revisionValue += 1
        let revision = currentRevision
        let waiters = revisionWaiters.values
        revisionWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume(returning: revision)
        }
    }

    private func cancelRevisionWaiter(_ waiterID: UUID) {
        revisionWaiters.removeValue(forKey: waiterID)?.resume(
            throwing: CancellationError()
        )
    }
}
