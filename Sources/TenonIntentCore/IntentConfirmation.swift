// @domain: intent-bus

import Foundation

public struct IntentConfirmationRequest: Sendable, Equatable {
    public let envelope: IntentEnvelope
    public let contract: IntentContract
    public let providerID: ProviderID
    /// The effective confirmation mode after caller-specific narrowing.
    ///
    /// A `.policy` request may offer standing-consent choices. An `.always` request may
    /// only approve the invocation currently being presented, even when the contract's
    /// declared mode was narrowed from `.policy` by the dispatcher.
    public let confirmation: IntentConfirmation

    public init(
        envelope: IntentEnvelope,
        contract: IntentContract,
        providerID: ProviderID,
        confirmation: IntentConfirmation
    ) {
        self.envelope = envelope
        self.contract = contract
        self.providerID = providerID
        self.confirmation = confirmation
    }
}

public enum IntentConfirmationDecision: Sendable, Equatable, CaseIterable {
    /// Approves only the currently coalesced confirmation wave.
    case allowOnce
    /// Remembers approval for this caller and contract.
    case alwaysAllow
    /// Remembers approval for every `.policy` contract invoked by this caller identity.
    case alwaysAllowForCaller
    case denied
}

public enum IntentConfirmationDisposition: Sendable, Equatable {
    case notRequired
    case approved
    case denied
    case cancelled
    case timedOut
}

public struct IntentConfirmationAuthorizer: Sendable {
    public typealias Handler =
        @Sendable (IntentConfirmationRequest) async -> IntentConfirmationDecision

    public static let failClosed = IntentConfirmationAuthorizer { _ in .denied }

    private let handler: Handler

    public init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    public func authorize(
        _ request: IntentConfirmationRequest
    ) async -> IntentConfirmationDecision {
        await handler(request)
    }
}
