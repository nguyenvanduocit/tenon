import Foundation

public struct IntentConfirmationRequest: Sendable, Equatable {
    public let envelope: IntentEnvelope
    public let contract: IntentContract
    public let providerID: ProviderID

    public init(
        envelope: IntentEnvelope,
        contract: IntentContract,
        providerID: ProviderID
    ) {
        self.envelope = envelope
        self.contract = contract
        self.providerID = providerID
    }
}

public enum IntentConfirmationDecision: Sendable, Equatable {
    case approved
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
