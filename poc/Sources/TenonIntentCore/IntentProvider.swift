// @domain: intent-bus
import Foundation

public struct IntentProgress: Sendable, Equatable {
    public let completed: Double
    public let total: Double?
    public let message: String?

    public init(completed: Double, total: Double? = nil, message: String? = nil) throws {
        guard completed.isFinite, completed >= 0 else {
            throw IntentProgressError.invalidCompleted
        }
        if let total {
            guard total.isFinite, total >= completed else {
                throw IntentProgressError.invalidTotal
            }
        }
        self.completed = completed
        self.total = total
        self.message = message
    }
}

public enum IntentProgressError: Error, Sendable, Equatable {
    case invalidCompleted
    case invalidTotal
}

public struct IntentProviderSendRequest: Sendable, Equatable {
    public let intentID: IntentID
    public let input: IntentValue
    public let target: ProviderID?
    public let idempotencyKey: String?
    public let requestedTimeout: Duration?
    public let scopeOverride: InvocationScopeOverride?

    public init(
        intentID: IntentID,
        input: IntentValue,
        target: ProviderID? = nil,
        idempotencyKey: String? = nil,
        requestedTimeout: Duration? = nil,
        scopeOverride: InvocationScopeOverride? = nil
    ) {
        self.intentID = intentID
        self.input = input
        self.target = target
        self.idempotencyKey = idempotencyKey
        self.requestedTimeout = requestedTimeout
        self.scopeOverride = scopeOverride
    }
}

public struct IntentProviderContext: Sendable {
    public let requestID: UUID
    private let filesystemPaths: [String: AuthorizedFilesystemPath]
    private let networkHosts: [String: AuthorizedNetworkHost]
    private let progressSink: @Sendable (IntentProgress) async -> Void
    private let nestedSend: @Sendable (IntentProviderSendRequest) async -> IntentResult

    init(
        requestID: UUID,
        authorizedFilesystemPaths: [AuthorizedFilesystemPath] = [],
        authorizedNetworkHosts: [AuthorizedNetworkHost] = [],
        nestedSend: @escaping @Sendable (IntentProviderSendRequest) async -> IntentResult,
        progressSink: @escaping @Sendable (IntentProgress) async -> Void = { _ in }
    ) {
        self.requestID = requestID
        filesystemPaths = Dictionary(
            authorizedFilesystemPaths.map { ($0.requestedPath, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        networkHosts = Dictionary(
            authorizedNetworkHosts.map { ($0.requestedHost, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.nestedSend = nestedSend
        self.progressSink = progressSink
    }

    public var isCancelled: Bool {
        Task.isCancelled
    }

    public func reportProgress(_ progress: IntentProgress) async {
        guard !Task.isCancelled else { return }
        await progressSink(progress)
    }

    public func checkCancellation() throws {
        try Task.checkCancellation()
    }

    public func authorizedFilesystemPath(
        for requestedPath: String
    ) -> AuthorizedFilesystemPath? {
        filesystemPaths[requestedPath]
    }

    public func authorizedNetworkHost(
        for requestedHost: String
    ) -> AuthorizedNetworkHost? {
        networkHosts[requestedHost]
    }

    public func send(_ request: IntentProviderSendRequest) async -> IntentResult {
        await nestedSend(request)
    }
}

public struct IntentProviderFailure: Sendable, Equatable {
    public let code: IntentErrorCode
    public let details: IntentValue?
    public let retryable: Bool
    public let retryAfterMilliseconds: UInt64?

    public init(
        code: IntentErrorCode,
        details: IntentValue? = nil,
        retryable: Bool = false,
        retryAfterMilliseconds: UInt64? = nil
    ) {
        self.code = code
        self.details = details
        self.retryable = retryable
        self.retryAfterMilliseconds = retryAfterMilliseconds
    }
}

public enum IntentProviderReply: Sendable, Equatable {
    case success(IntentValue)
    case failure(IntentProviderFailure)
}

public struct IntentProviderBinding: Sendable {
    public typealias Operation = @Sendable (
        IntentEnvelope,
        IntentProviderContext
    ) async throws -> IntentProviderReply

    public let intentID: IntentID
    public let isExported: Bool
    private let operation: Operation

    public init(
        intentID: IntentID,
        isExported: Bool = true,
        operation: @escaping Operation
    ) {
        self.intentID = intentID
        self.isExported = isExported
        self.operation = operation
    }

    public func invoke(
        envelope: IntentEnvelope,
        context: IntentProviderContext
    ) async throws -> IntentProviderReply {
        try await operation(envelope, context)
    }
}

public enum IntentProviderOwner: Sendable, Equatable, Hashable {
    case core
    case plugin(id: PluginID, installationID: UUID)

    public func principal(sessionRevision: UInt64) -> IntentPrincipal {
        switch self {
        case .core:
            IntentPrincipal(
                id: "core:tenon",
                kind: .core,
                sessionRevision: sessionRevision
            )
        case let .plugin(id, installationID):
            IntentPrincipal(
                id: "plugin:\(id.rawValue):\(installationID.uuidString.lowercased())",
                kind: .plugin,
                sessionRevision: sessionRevision
            )
        }
    }

    /// Reconstructs the immutable installation owner encoded by a plugin principal.
    ///
    /// Providers use this when caller-owned resources need the installation UUID as
    /// part of their storage key. The final canonical-ID comparison rejects alternate
    /// spellings rather than letting two strings identify the same installation.
    public static func pluginOwner(
        from principal: IntentPrincipal
    ) throws -> IntentProviderOwner {
        guard principal.kind == .plugin,
              principal.audience == .plugin
        else {
            throw IntentPrincipalIdentityError.pluginPrincipalRequired
        }
        let components = principal.id.split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        guard components.count == 3,
              components[0] == "plugin",
              let pluginID = try? PluginID(String(components[1])),
              let installationID = UUID(uuidString: String(components[2]))
        else {
            throw IntentPrincipalIdentityError.malformedPluginPrincipal
        }
        let owner = IntentProviderOwner.plugin(
            id: pluginID,
            installationID: installationID
        )
        guard owner.principal(
            sessionRevision: principal.sessionRevision
        ).id == principal.id
        else {
            throw IntentPrincipalIdentityError.malformedPluginPrincipal
        }
        return owner
    }
}

public enum IntentPrincipalIdentityError: Error, Sendable, Equatable {
    case pluginPrincipalRequired
    case malformedPluginPrincipal
}

public enum ProviderRetirementReason: Sendable, Equatable {
    case drained
    case drainDeadlineExceeded
    case disabled
    case uninstalled
    case stagingFailed
}

/// One physical execution lane within a provider generation.
///
/// A lane is deliberately simple: it names the contracts sharing one bounded,
/// serial mailbox. The provider generation remains the lifecycle, routing, and
/// authority boundary; lanes only prevent unrelated work from head-of-line
/// blocking each other.
public struct ProviderExecutionLane: Sendable {
    public let intentIDs: Set<IntentID>
    public let mailbox: IntentMailbox

    public init(
        intentIDs: Set<IntentID>,
        mailbox: IntentMailbox
    ) throws {
        guard !intentIDs.isEmpty else {
            throw ProviderExecutionLaneError.emptyIntentInventory
        }
        self.intentIDs = intentIDs
        self.mailbox = mailbox
    }
}

public enum ProviderExecutionLaneError: Error, Sendable, Equatable {
    case emptyIntentInventory
}

public struct ProviderGenerationCandidate: Sendable {
    public typealias Shutdown = @Sendable (ProviderRetirementReason) async -> Void

    public let providerID: ProviderID
    public let owner: IntentProviderOwner
    public let principal: IntentPrincipal
    public let generation: UInt64
    public let bindings: [IntentID: IntentProviderBinding]
    public let policyFingerprint: PolicyFingerprint
    public let executionLanes: [ProviderExecutionLane]
    public let drainTimeout: Duration
    private let mailboxesByIntent: [IntentID: IntentMailbox]
    private let shutdownOperation: Shutdown

    public init(
        providerID: ProviderID,
        owner: IntentProviderOwner,
        principal: IntentPrincipal,
        generation: UInt64,
        bindings: [IntentProviderBinding],
        policyFingerprint: PolicyFingerprint,
        mailbox: IntentMailbox,
        drainTimeout: Duration = .seconds(5),
        shutdown: @escaping Shutdown = { _ in }
    ) throws {
        let lane = try ProviderExecutionLane(
            intentIDs: Set(bindings.map(\.intentID)),
            mailbox: mailbox
        )
        try self.init(
            providerID: providerID,
            owner: owner,
            principal: principal,
            generation: generation,
            bindings: bindings,
            policyFingerprint: policyFingerprint,
            executionLanes: [lane],
            drainTimeout: drainTimeout,
            shutdown: shutdown
        )
    }

    public init(
        providerID: ProviderID,
        owner: IntentProviderOwner,
        principal: IntentPrincipal,
        generation: UInt64,
        bindings: [IntentProviderBinding],
        policyFingerprint: PolicyFingerprint,
        executionLanes: [ProviderExecutionLane],
        drainTimeout: Duration = .seconds(5),
        shutdown: @escaping Shutdown = { _ in }
    ) throws {
        guard generation > 0 else {
            throw ProviderGenerationError.invalidGeneration
        }
        guard principal == owner.principal(sessionRevision: principal.sessionRevision) else {
            throw ProviderGenerationError.principalOwnerMismatch
        }
        guard !bindings.isEmpty else {
            throw ProviderGenerationError.emptyBindings
        }
        guard drainTimeout > .zero else {
            throw ProviderGenerationError.invalidDrainTimeout
        }
        guard !executionLanes.isEmpty else {
            throw ProviderGenerationError.emptyExecutionLanes
        }

        var indexed: [IntentID: IntentProviderBinding] = [:]
        for binding in bindings {
            guard indexed.updateValue(binding, forKey: binding.intentID) == nil else {
                throw ProviderGenerationError.duplicateBinding(binding.intentID)
            }
        }

        var routed: [IntentID: IntentMailbox] = [:]
        var mailboxIdentities: Set<ObjectIdentifier> = []
        for lane in executionLanes {
            let mailboxIdentity = ObjectIdentifier(lane.mailbox)
            guard mailboxIdentities.insert(mailboxIdentity).inserted else {
                throw ProviderGenerationError.reusedExecutionMailbox
            }
            for intentID in lane.intentIDs {
                guard indexed[intentID] != nil else {
                    throw ProviderGenerationError.unexpectedExecutionLaneIntent(
                        intentID
                    )
                }
                guard routed.updateValue(
                    lane.mailbox,
                    forKey: intentID
                ) == nil else {
                    throw ProviderGenerationError.duplicateExecutionLaneIntent(
                        intentID
                    )
                }
            }
        }
        if let missing = Set(indexed.keys)
            .subtracting(routed.keys)
            .sorted(by: { $0.rawValue < $1.rawValue })
            .first
        {
            throw ProviderGenerationError.missingExecutionLaneIntent(missing)
        }

        self.providerID = providerID
        self.owner = owner
        self.principal = principal
        self.generation = generation
        self.bindings = indexed
        self.policyFingerprint = policyFingerprint
        self.executionLanes = executionLanes
        self.drainTimeout = drainTimeout
        mailboxesByIntent = routed
        self.shutdownOperation = shutdown
    }

    public func mailbox(for intentID: IntentID) -> IntentMailbox? {
        mailboxesByIntent[intentID]
    }

    public func shutdown(reason: ProviderRetirementReason) async {
        await shutdownOperation(reason)
    }
}

public enum ProviderGenerationError: Error, Sendable, Equatable {
    case invalidGeneration
    case principalOwnerMismatch
    case emptyBindings
    case duplicateBinding(IntentID)
    case invalidDrainTimeout
    case emptyExecutionLanes
    case reusedExecutionMailbox
    case unexpectedExecutionLaneIntent(IntentID)
    case duplicateExecutionLaneIntent(IntentID)
    case missingExecutionLaneIntent(IntentID)
}
