// @domain: intent-bus
import Foundation

public enum IntentAudience: String, Sendable, Codable, CaseIterable {
    case core
    case plugin
    /// A person acting through a host surface — the palette, the launcher, a rebindable
    /// product keybinding, a click on something the host rendered. These are surfaces of
    /// one principal rather than a principal each, which is why built-in UI needs no
    /// identity of its own. See `docs/design-open-handlers.md`.
    case user
    case cli
    case agent
}

public struct IntentPrincipal: Sendable, Equatable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case core
        case plugin
        case user
        case cli
        case agent
    }

    public let id: String
    public let kind: Kind
    public let sessionRevision: UInt64

    /// Audience is a type-level consequence of principal kind. Keeping no
    /// independently writable audience field makes identity/audience spoofing
    /// structurally impossible.
    public var audience: IntentAudience {
        switch kind {
        case .core: .core
        case .plugin: .plugin
        case .user: .user
        case .cli: .cli
        case .agent: .agent
        }
    }

    public init(
        id: String,
        kind: Kind,
        sessionRevision: UInt64
    ) {
        self.id = id
        self.kind = kind
        self.sessionRevision = sessionRevision
    }
}

public struct InvocationScope: Sendable, Equatable, Hashable, Codable {
    public let workspaceID: UUID?
    public let tabID: UUID?
    public let paneID: UUID?
    public let userGestureID: UUID?

    public init(
        workspaceID: UUID? = nil,
        tabID: UUID? = nil,
        paneID: UUID? = nil,
        userGestureID: UUID? = nil
    ) {
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.paneID = paneID
        self.userGestureID = userGestureID
    }
}

/// Caller-selectable entity retargeting for an intent invocation.
///
/// The user-gesture token is intentionally absent: only the host can mint or
/// preserve that proof. Scope follows the workspace → tab → pane hierarchy:
/// retargeting a workspace clears an inherited tab and pane, while retargeting
/// a tab clears an inherited pane.
public struct InvocationScopeOverride: Sendable, Equatable, Hashable, Codable {
    public let workspaceID: UUID?
    public let tabID: UUID?
    public let paneID: UUID?

    public init(
        workspaceID: UUID? = nil,
        tabID: UUID? = nil,
        paneID: UUID? = nil
    ) {
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.paneID = paneID
    }

    public func applying(to inherited: InvocationScope) -> InvocationScope {
        InvocationScope(
            workspaceID: workspaceID ?? inherited.workspaceID,
            tabID: tabID ?? (workspaceID == nil ? inherited.tabID : nil),
            paneID: paneID ?? (
                workspaceID == nil && tabID == nil ? inherited.paneID : nil
            ),
            userGestureID: inherited.userGestureID
        )
    }
}

public enum IntentEffectKind: String, Sendable, Codable, CaseIterable {
    case read
    case write
    case destructive
}

public enum IntentIdempotencyMode: String, Sendable, Codable, CaseIterable {
    case none
    case keyed
}

public enum IntentConfirmation: String, Sendable, Codable, CaseIterable {
    case never
    case policy
    case always
}

public struct IntentEffects: Sendable, Equatable, Hashable {
    public static let pessimistic = IntentEffects(
        validatedKind: .write,
        idempotency: .none,
        retentionMilliseconds: nil,
        confirmation: .policy,
        external: true
    )

    public let kind: IntentEffectKind
    public let idempotency: IntentIdempotencyMode
    public let retentionMilliseconds: UInt64?
    public let confirmation: IntentConfirmation
    public let external: Bool

    public init(
        kind: IntentEffectKind,
        idempotency: IntentIdempotencyMode,
        retentionMilliseconds: UInt64?,
        confirmation: IntentConfirmation,
        external: Bool
    ) throws {
        switch (idempotency, retentionMilliseconds) {
        case (.keyed, .none):
            throw IntentEffectsError.keyedRetentionRequired
        case let (.keyed, .some(value)) where value == 0:
            throw IntentEffectsError.keyedRetentionMustBePositive
        case (.none, .some):
            throw IntentEffectsError.retentionRequiresKeyedIdempotency
        default:
            break
        }

        self.init(
            validatedKind: kind,
            idempotency: idempotency,
            retentionMilliseconds: retentionMilliseconds,
            confirmation: confirmation,
            external: external
        )
    }

    private init(
        validatedKind kind: IntentEffectKind,
        idempotency: IntentIdempotencyMode,
        retentionMilliseconds: UInt64?,
        confirmation: IntentConfirmation,
        external: Bool
    ) {
        self.kind = kind
        self.idempotency = idempotency
        self.retentionMilliseconds = retentionMilliseconds
        self.confirmation = confirmation
        self.external = external
    }
}

public enum IntentEffectsError: Error, Sendable, Equatable {
    case keyedRetentionRequired
    case keyedRetentionMustBePositive
    case retentionRequiresKeyedIdempotency
}

extension IntentEffects: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case idempotency
        case retentionMilliseconds = "retentionMs"
        case confirmation
        case external
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(IntentEffectKind.self, forKey: .kind),
            idempotency: container.decode(IntentIdempotencyMode.self, forKey: .idempotency),
            retentionMilliseconds: container.decodeIfPresent(
                UInt64.self,
                forKey: .retentionMilliseconds
            ),
            confirmation: container.decode(IntentConfirmation.self, forKey: .confirmation),
            external: container.decode(Bool.self, forKey: .external)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(idempotency, forKey: .idempotency)
        try container.encodeIfPresent(
            retentionMilliseconds,
            forKey: .retentionMilliseconds
        )
        try container.encode(confirmation, forKey: .confirmation)
        try container.encode(external, forKey: .external)
    }
}

public struct IntentEnvelope: Sendable, Equatable {
    public let requestID: UUID
    public let traceID: UUID
    public let parentRequestID: UUID?
    public let name: IntentID
    public let input: IntentValue
    public let caller: IntentPrincipal
    public let scope: InvocationScope
    public let deadline: ContinuousClock.Instant
    public let target: ProviderID?
    public let idempotencyKey: String?

    public init(
        requestID: UUID,
        traceID: UUID,
        parentRequestID: UUID?,
        name: IntentID,
        input: IntentValue,
        caller: IntentPrincipal,
        scope: InvocationScope,
        deadline: ContinuousClock.Instant,
        target: ProviderID?,
        idempotencyKey: String?
    ) {
        self.requestID = requestID
        self.traceID = traceID
        self.parentRequestID = parentRequestID
        self.name = name
        self.input = input
        self.caller = caller
        self.scope = scope
        self.deadline = deadline
        self.target = target
        self.idempotencyKey = idempotencyKey
    }
}
