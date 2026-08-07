// @domain: intent-bus
import Foundation

/// Composition root for the independent kernel concerns and provider activation boundary.
///
/// This value owns no mutable policy or routing behavior itself; callers may depend on
/// only the component they need while every adapter still shares one dispatcher.
public struct IntentKernelComponents: Sendable {
    public let catalog: ContractCatalog
    public let policy: PolicyEngine
    let registry: ProviderRegistry
    public let providerActivation: ProviderActivationCoordinator
    public let idempotency: IntentIdempotencyStore
    public let telemetry: IntentTelemetry
    public let dispatcher: IntentDispatcher

    public init(
        schemaLimits: IntentSchemaLimits = .default,
        idempotencyLimits: IntentIdempotencyLimits? = nil,
        persistence: sending any IntentIdempotencyPersistence,
        telemetryCapacity: Int = 2_000,
        dispatcherLimits: IntentDispatcherLimits? = nil,
        confirmationAuthorizer: IntentConfirmationAuthorizer = .failClosed,
        progressSink: @escaping IntentDispatcher.ProgressSink = { _ in }
    ) throws {
        let resolvedIdempotencyLimits = try idempotencyLimits
            ?? IntentIdempotencyLimits()
        let resolvedDispatcherLimits = try dispatcherLimits
            ?? IntentDispatcherLimits()
        let catalog = ContractCatalog(
            compiler: IntentSchemaCompiler(limits: schemaLimits)
        )
        let policy = PolicyEngine()
        let registry = ProviderRegistry()
        let providerActivation = ProviderActivationCoordinator(
            catalog: catalog,
            registry: registry
        )
        let idempotency = try IntentIdempotencyStore(
            limits: resolvedIdempotencyLimits,
            persistence: persistence
        )
        let telemetry = try IntentTelemetry(completedCapacity: telemetryCapacity)
        let dispatcher = IntentDispatcher(
            catalog: catalog,
            policy: policy,
            registry: registry,
            idempotency: idempotency,
            telemetry: telemetry,
            limits: resolvedDispatcherLimits,
            confirmationAuthorizer: confirmationAuthorizer,
            progressSink: progressSink
        )

        self.catalog = catalog
        self.policy = policy
        self.registry = registry
        self.providerActivation = providerActivation
        self.idempotency = idempotency
        self.telemetry = telemetry
        self.dispatcher = dispatcher
    }
}
