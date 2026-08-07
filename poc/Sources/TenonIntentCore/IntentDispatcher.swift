import Foundation

public struct IntentDispatcherSnapshot: Sendable, Equatable {
    public let ruleRevision: UInt64
    public let rules: [IntentID: IntentDispatchRule]
    public let inFlightRequests: Int
    public let inFlightEncodedBytes: Int
    public let inFlightByPrincipal: [IntentPrincipal: Int]
}

public enum IntentDispatcherError: Error, Sendable, Equatable {
    case ruleRevisionOverflow
    case configurationBusy
}

public actor IntentDispatcher {
    public typealias ProgressSink = @Sendable (IntentProgressNotification) async -> Void

    typealias CallerConsentPersistence = @Sendable (
        _ key: CallerConsentKey,
        _ fence: CallerConsentGrantFence
    ) async throws -> Bool

    private struct CausalContext: Sendable {
        let traceID: UUID
        let parentRequestID: UUID
        let parentDeadline: ContinuousClock.Instant
    }

    private struct Usage: Sendable {
        var requests = 0
        var bytes = 0
    }

    private struct ProviderNode: Sendable, Hashable {
        let providerID: ProviderID
        let generation: UInt64
    }

    private struct ExecutionReservation: Sendable {
        let requestID: UUID
        let parentRequestID: UUID?
        let principal: IntentPrincipal
        let encodedBytes: Int
        let admissionClass: IntentAdmissionClass
        let node: ProviderNode
        let parentNode: ProviderNode?
    }

    private struct PreparedIdempotency: Sendable {
        let key: IntentIdempotencyClaimKey
        let fingerprint: IntentIdempotencyFingerprint
        let retentionMilliseconds: UInt64
        let maximumTerminalResultBytes: Int
    }

    private struct ProviderReplyValidation: Sendable {
        let reply: IntentProviderReply
        let isContractValid: Bool
    }

    private enum CallerConsentWaveOutcome: Sendable {
        case approved
        case denied
        case persistenceFailed
        case cancelled
    }

    private enum CallerConsentAuthorization: Sendable {
        case standingConsent
        case approved
        case denied
    }

    private struct CallerConsentFlight: Sendable {
        let id: UUID
        let task: Task<Void, Never>
        let grantFence: CallerConsentGrantFence
        var waiters: [
            UUID: CheckedContinuation<CallerConsentWaveOutcome, Never>
        ]
    }

    private struct DiscoveryCacheKey: Sendable, Hashable {
        let caller: IntentPrincipal
        let catalogRevision: UInt64
        let ruleRevision: UInt64
        let policyRevision: PolicyRevision
        let providerRevision: ProviderRegistryRevision
        let projection: IntentDiscoveryProjection
    }

    private enum GlobalAdmissionFailure: Error {
        case overloaded
        case cycle
    }

    private let catalog: ContractCatalog
    private let policy: PolicyEngine
    private let registry: ProviderRegistry
    private let idempotency: IntentIdempotencyStore
    private let telemetry: IntentTelemetry
    private let limits: IntentDispatcherLimits
    private let progressSink: ProgressSink
    private let confirmationAuthorizer: IntentConfirmationAuthorizer
    private let callerConsentPersistence: CallerConsentPersistence

    private var rules: [IntentID: IntentDispatchRule] = [:]
    private var ruleRevision: UInt64 = 0
    private var reservations: [UUID: ExecutionReservation] = [:]
    private var waitEdges: [ProviderNode: [ProviderNode: Int]] = [:]
    private var usage = Usage()
    private var backgroundUsage = Usage()
    private var usageByPrincipal: [IntentPrincipal: Usage] = [:]
    private var configurationMutationInProgress = false
    private var discoveryCache: [DiscoveryCacheKey: IntentDiscoverySnapshot] = [:]
    private var callerConsentFlights: [CallerConsentKey: CallerConsentFlight] = [:]
    private let maximumDiscoveryCacheEntries = 128

    public init(
        catalog: ContractCatalog,
        policy: PolicyEngine,
        registry: ProviderRegistry,
        idempotency: IntentIdempotencyStore,
        telemetry: IntentTelemetry,
        limits: IntentDispatcherLimits,
        confirmationAuthorizer: IntentConfirmationAuthorizer = .failClosed,
        progressSink: @escaping ProgressSink = { _ in }
    ) {
        self.catalog = catalog
        self.policy = policy
        self.registry = registry
        self.idempotency = idempotency
        self.telemetry = telemetry
        self.limits = limits
        self.confirmationAuthorizer = confirmationAuthorizer
        self.progressSink = progressSink
        callerConsentPersistence = { key, fence in
            try await policy.grantStandingConsent(
                for: key,
                guardedBy: fence
            )
        }
    }

    init(
        catalog: ContractCatalog,
        policy: PolicyEngine,
        registry: ProviderRegistry,
        idempotency: IntentIdempotencyStore,
        telemetry: IntentTelemetry,
        limits: IntentDispatcherLimits,
        confirmationAuthorizer: IntentConfirmationAuthorizer,
        callerConsentPersistence: @escaping CallerConsentPersistence,
        progressSink: @escaping ProgressSink = { _ in }
    ) {
        self.catalog = catalog
        self.policy = policy
        self.registry = registry
        self.idempotency = idempotency
        self.telemetry = telemetry
        self.limits = limits
        self.confirmationAuthorizer = confirmationAuthorizer
        self.callerConsentPersistence = callerConsentPersistence
        self.progressSink = progressSink
    }

    public func registerRule(_ rule: IntentDispatchRule) async throws {
        try beginConfigurationMutation()
        defer { releaseConfigurationMutation() }

        let catalogSnapshot = await catalog.snapshot
        guard let contract = catalogSnapshot.contract(named: rule.intentID) else {
            throw IntentDispatchRuleError.contractNotFound(rule.intentID)
        }
        for audience in rule.exposure.discoverableBy
            .union(rule.exposure.invocableBy)
            where !contract.audiences.contains(audience)
        {
            throw IntentDispatchRuleError.exposureExceedsContractAudience(audience)
        }

        if rules[rule.intentID] == rule {
            return
        }
        guard ruleRevision < UInt64.max else {
            throw IntentDispatcherError.ruleRevisionOverflow
        }
        try await policy.setExposure(rule.exposure, for: rule.intentID)
        rules[rule.intentID] = rule
        ruleRevision += 1
        discoveryCache.removeAll(keepingCapacity: true)
    }

    public func removeRule(for intentID: IntentID) async throws {
        try beginConfigurationMutation()
        defer { releaseConfigurationMutation() }

        guard rules[intentID] != nil else { return }
        guard ruleRevision < UInt64.max else {
            throw IntentDispatcherError.ruleRevisionOverflow
        }
        try await policy.removeExposure(for: intentID)
        rules.removeValue(forKey: intentID)
        ruleRevision += 1
        discoveryCache.removeAll(keepingCapacity: true)
    }

    public func snapshot() -> IntentDispatcherSnapshot {
        IntentDispatcherSnapshot(
            ruleRevision: ruleRevision,
            rules: rules,
            inFlightRequests: usage.requests,
            inFlightEncodedBytes: usage.bytes,
            inFlightByPrincipal: usageByPrincipal.mapValues(\.requests)
        )
    }

    public func discover(
        for caller: IntentPrincipal,
        projection: IntentDiscoveryProjection = .callable
    ) async -> IntentDiscoverySnapshot {
        while true {
            let capturedRuleRevision = ruleRevision
            let capturedRules = rules
            async let catalogValue = catalog.snapshot
            async let policyValue = policy.snapshot()
            async let registryValue = registry.snapshot()
            let (catalogSnapshot, policySnapshot, registrySnapshot) = await (
                catalogValue,
                policyValue,
                registryValue
            )
            guard capturedRuleRevision == ruleRevision else {
                continue
            }

            let key = DiscoveryCacheKey(
                caller: caller,
                catalogRevision: catalogSnapshot.revision,
                ruleRevision: capturedRuleRevision,
                policyRevision: policySnapshot.revision,
                providerRevision: registrySnapshot.revision,
                projection: projection
            )
            if let cached = discoveryCache[key] {
                return cached
            }

            let items = capturedRules.values.compactMap { rule -> IntentDiscoveryItem? in
                guard let contract = catalogSnapshot.contract(named: rule.intentID) else {
                    return nil
                }
                let requiredCapabilities = Set(
                    rule.capabilityBindings.map(\.capability)
                )
                let decision = policySnapshot.discoveryDecision(
                    PolicyDiscoveryRequest(
                        intent: rule.intentID,
                        caller: caller,
                        requiredCapabilities: requiredCapabilities
                    )
                )
                guard case .allowed = decision.verdict else {
                    return nil
                }

                let providers = registrySnapshot.generations.compactMap {
                    generation -> ProviderID? in
                    guard generation.lifecycle == .active,
                          generation.isHealthy,
                          generation.exportedIntentIDs.contains(rule.intentID)
                    else {
                        return nil
                    }
                    return generation.providerID
                }
                guard projection == .catalog || !providers.isEmpty else {
                    return nil
                }
                return IntentDiscoveryItem(
                    contract: contract,
                    activeProviders: Array(Set(providers)).sorted {
                        $0.rawValue < $1.rawValue
                    }
                )
            }.sorted { $0.name.rawValue < $1.name.rawValue }

            let snapshot = IntentDiscoverySnapshot(
                revision: IntentDiscoveryRevision(
                    catalog: catalogSnapshot.revision,
                    rules: capturedRuleRevision,
                    policy: policySnapshot.revision,
                    providers: registrySnapshot.revision,
                    principal: caller,
                    projection: projection
                ),
                items: items
            )
            if discoveryCache.count >= maximumDiscoveryCacheEntries {
                discoveryCache.removeAll(keepingCapacity: true)
            }
            discoveryCache[key] = snapshot
            return snapshot
        }
    }

    public func send(_ request: IntentDispatchRequest) async -> IntentResult {
        await send(request, causalContext: nil)
    }

    private func send(
        _ request: IntentDispatchRequest,
        causalContext: CausalContext?
    ) async -> IntentResult {
        let requestID = UUID()
        let traceID = causalContext?.traceID ?? UUID()
        let parentRequestID = causalContext?.parentRequestID
        let rule = rules[request.intentID]
        let requestedTimeout = request.requestedTimeout
            ?? rule?.maximumTimeout
            ?? limits.maximumTimeout
        let maximumTimeout = min(
            rule?.maximumTimeout ?? limits.maximumTimeout,
            limits.maximumTimeout
        )
        let clock = ContinuousClock()
        let now = clock.now
        var timeout = min(requestedTimeout, maximumTimeout)
        if let parentDeadline = causalContext?.parentDeadline {
            timeout = min(timeout, now.duration(to: parentDeadline))
        }
        let deadline = now.advanced(by: max(.zero, timeout))
        let envelope = IntentEnvelope(
            requestID: requestID,
            traceID: traceID,
            parentRequestID: parentRequestID,
            name: request.intentID,
            input: request.input,
            caller: request.caller,
            scope: request.scope,
            deadline: deadline,
            target: request.target,
            idempotencyKey: request.idempotencyKey
        )

        guard timeout > .zero else {
            await telemetry.begin(envelope, inputBytes: 0)
            return await finishWithoutExecution(
                envelope: envelope,
                result: Self.failure(
                    code: causalContext == nil ? .invalidInput : .deadlineExceeded,
                    details: causalContext == nil
                        ? .object(["reason": .string("timeout-must-be-positive")])
                        : nil,
                    requestID: requestID
                )
            )
        }

        guard let rule else {
            await telemetry.begin(envelope, inputBytes: 0)
            return await finishWithoutExecution(
                envelope: envelope,
                result: Self.failure(
                    code: .unknownIntent,
                    requestID: requestID
                )
            )
        }

        let accounting: IntentValueAccounting
        do {
            accounting = try request.input.accounting(limits: rule.valueLimits)
        } catch {
            await telemetry.begin(envelope, inputBytes: 0)
            return await finishWithoutExecution(
                envelope: envelope,
                result: Self.failure(
                    code: .invalidInput,
                    details: .object(["reason": .string("value-budget-exceeded")]),
                    requestID: requestID
                )
            )
        }
        await telemetry.begin(envelope, inputBytes: accounting.encodedBytes)

        let catalogSnapshot = await catalog.snapshot
        guard let contract = catalogSnapshot.contract(named: request.intentID) else {
            return await finishWithoutExecution(
                envelope: envelope,
                result: Self.failure(code: .unknownIntent, requestID: requestID)
            )
        }

        do {
            let validation = try contract.validateInput(request.input)
            guard validation.isValid else {
                return await finishWithoutExecution(
                    envelope: envelope,
                    result: Self.failure(
                        code: .invalidInput,
                        details: Self.validationDetails(validation.issues),
                        requestID: requestID
                    )
                )
            }
        } catch {
            return await finishWithoutExecution(
                envelope: envelope,
                result: Self.failure(code: .internal, requestID: requestID)
            )
        }
        await telemetry.markValidated(requestID: requestID)

        let capabilityRequirements: [CapabilityRequirement]
        do {
            capabilityRequirements = try rule.capabilityRequirements(input: request.input)
        } catch {
            return await finishWithoutExecution(
                envelope: envelope,
                result: Self.failure(
                    code: .invalidInput,
                    details: .object(["reason": .string("capability-path-invalid")]),
                    requestID: requestID
                )
            )
        }

        let basePolicy = await policy.authorize(
            PolicyInvocationRequest(
                envelope: envelope,
                capabilityRequirements: capabilityRequirements,
                providerConsent: .notRequired
            )
        )
        guard case .allowed = basePolicy.verdict else {
            return await finishWithoutExecution(
                envelope: envelope,
                result: Self.policyFailure(
                    decision: basePolicy,
                    requestID: requestID
                )
            )
        }
        await telemetry.markAuthorized(
            requestID: requestID,
            policyRevision: basePolicy.policyRevision
        )

        if Task.isCancelled {
            return await finishWithoutExecution(
                envelope: envelope,
                result: Self.failure(code: .cancelled, requestID: requestID)
            )
        }
        if ContinuousClock.now >= deadline {
            return await finishWithoutExecution(
                envelope: envelope,
                result: Self.failure(code: .deadlineExceeded, requestID: requestID)
            )
        }

        let preparedIdempotency: PreparedIdempotency?
        do {
            preparedIdempotency = try Self.prepareIdempotency(
                contract: contract,
                envelope: envelope,
                limits: rule.valueLimits
            )
        } catch {
            return await finishWithoutExecution(
                envelope: envelope,
                result: Self.failure(
                    code: .invalidInput,
                    details: .object(["reason": .string("idempotency-key-invalid")]),
                    requestID: requestID
                )
            )
        }

        if let preparedIdempotency {
            do {
                if let decision = try await idempotency.lookup(
                    key: preparedIdempotency.key,
                    fingerprint: preparedIdempotency.fingerprint
                ) {
                    return await finishExistingIdempotency(
                        decision,
                        prepared: preparedIdempotency,
                        envelope: envelope
                    )
                }
            } catch {
                return await finishWithoutExecution(
                    envelope: envelope,
                    result: Self.failure(code: .internal, requestID: requestID)
                )
            }
        }

        let selection: ProviderSelection
        do {
            selection = try await registry.resolveAndHold(
                ProviderResolutionRequest(
                    intentID: request.intentID,
                    explicitTarget: request.target,
                    trustedDefault: rule.trustedDefault,
                    allowsAutomaticSelection: rule.allowsAutomaticSelection
                )
            )
        } catch let error as ProviderResolutionError {
            return await finishWithoutExecution(
                envelope: envelope,
                result: Self.resolutionFailure(error, requestID: requestID)
            )
        } catch {
            return await finishWithoutExecution(
                envelope: envelope,
                result: Self.failure(code: .internal, requestID: requestID)
            )
        }

        let providerConsentRequirement = Self.consentRequirement(
            rule: rule,
            contract: contract,
            selection: selection
        )
        let preConfirmationPolicyRequest = PolicyInvocationRequest(
            envelope: envelope,
            capabilityRequirements: capabilityRequirements,
            providerConsent: providerConsentRequirement
        )
        let preConfirmationPolicy = await policy.authorize(
            preConfirmationPolicyRequest
        )
        guard case .allowed = preConfirmationPolicy.verdict else {
            await registry.releaseSelection(selection)
            return await finishWithoutExecution(
                envelope: envelope,
                result: Self.policyFailure(
                    decision: preConfirmationPolicy,
                    requestID: requestID,
                    providerID: selection.providerID
                )
            )
        }
        await telemetry.markAuthorized(
            requestID: requestID,
            policyRevision: preConfirmationPolicy.policyRevision
        )

        if Task.isCancelled {
            await registry.releaseSelection(selection)
            return await finishWithoutExecution(
                envelope: envelope,
                result: Self.failure(code: .cancelled, requestID: requestID)
            )
        }
        if ContinuousClock.now >= deadline {
            await registry.releaseSelection(selection)
            return await finishWithoutExecution(
                envelope: envelope,
                result: Self.failure(code: .deadlineExceeded, requestID: requestID)
            )
        }

        let callerConsentRequirement: CallerConsentRequirement
        switch Self.effectiveConfirmation(contract: contract, caller: envelope.caller) {
        case .never:
            callerConsentRequirement = .notRequired
            await telemetry.markConfirmation(
                requestID: requestID,
                disposition: .notRequired
            )

        case .policy:
            let key = CallerConsentKey(
                caller: envelope.caller,
                contract: contract.name
            )
            callerConsentRequirement = .required(key)
            let outcome = await resolveCallerConsent(
                key: key,
                confirmationRequest: IntentConfirmationRequest(
                    envelope: envelope,
                    contract: contract,
                    providerID: selection.providerID
                ),
                deadline: deadline
            )
            if Task.isCancelled {
                await telemetry.markConfirmation(
                    requestID: requestID,
                    disposition: .cancelled
                )
                await registry.releaseSelection(selection)
                return await finishWithoutExecution(
                    envelope: envelope,
                    result: Self.failure(code: .cancelled, requestID: requestID)
                )
            }
            if ContinuousClock.now >= deadline {
                await telemetry.markConfirmation(
                    requestID: requestID,
                    disposition: .timedOut
                )
                await registry.releaseSelection(selection)
                return await finishWithoutExecution(
                    envelope: envelope,
                    result: Self.failure(code: .deadlineExceeded, requestID: requestID)
                )
            }
            switch outcome {
            case .approved:
                await telemetry.markConfirmation(
                    requestID: requestID,
                    disposition: .approved
                )
            case .denied:
                await telemetry.markConfirmation(
                    requestID: requestID,
                    disposition: .denied
                )
                await registry.releaseSelection(selection)
                return await finishWithoutExecution(
                    envelope: envelope,
                    result: Self.failure(
                        code: .denied,
                        details: .object([
                            "reason": .string("confirmation-denied")
                        ]),
                        requestID: requestID,
                        providerID: selection.providerID
                    )
                )
            case .persistenceFailed:
                await telemetry.markConfirmation(
                    requestID: requestID,
                    disposition: .approved
                )
                await registry.releaseSelection(selection)
                return await finishWithoutExecution(
                    envelope: envelope,
                    result: Self.failure(
                        code: .internal,
                        details: .object([
                            "reason": .string(
                                "caller-consent-persistence-failed"
                            )
                        ]),
                        requestID: requestID,
                        providerID: selection.providerID
                    )
                )
            case .cancelled:
                await telemetry.markConfirmation(
                    requestID: requestID,
                    disposition: .cancelled
                )
                await registry.releaseSelection(selection)
                return await finishWithoutExecution(
                    envelope: envelope,
                    result: Self.failure(code: .cancelled, requestID: requestID)
                )
            }

        case .always:
            callerConsentRequirement = .notRequired
            let confirmation = await confirmationAuthorizer.authorize(
                IntentConfirmationRequest(
                    envelope: envelope,
                    contract: contract,
                    providerID: selection.providerID
                )
            )
            if Task.isCancelled {
                await telemetry.markConfirmation(
                    requestID: requestID,
                    disposition: .cancelled
                )
                await registry.releaseSelection(selection)
                return await finishWithoutExecution(
                    envelope: envelope,
                    result: Self.failure(code: .cancelled, requestID: requestID)
                )
            }
            if ContinuousClock.now >= deadline {
                await telemetry.markConfirmation(
                    requestID: requestID,
                    disposition: .timedOut
                )
                await registry.releaseSelection(selection)
                return await finishWithoutExecution(
                    envelope: envelope,
                    result: Self.failure(code: .deadlineExceeded, requestID: requestID)
                )
            }
            guard confirmation == .approved else {
                await telemetry.markConfirmation(
                    requestID: requestID,
                    disposition: .denied
                )
                await registry.releaseSelection(selection)
                return await finishWithoutExecution(
                    envelope: envelope,
                    result: Self.failure(
                        code: .denied,
                        details: .object([
                            "reason": .string("confirmation-denied")
                        ]),
                        requestID: requestID,
                        providerID: selection.providerID
                    )
                )
            }
            await telemetry.markConfirmation(
                requestID: requestID,
                disposition: .approved
            )
        }

        let executionPolicyRequest = PolicyInvocationRequest(
            envelope: envelope,
            capabilityRequirements: capabilityRequirements,
            providerConsent: providerConsentRequirement,
            callerConsent: callerConsentRequirement
        )
        let postConfirmationPolicy = await policy.authorize(
            executionPolicyRequest
        )
        guard case .allowed = postConfirmationPolicy.verdict else {
            await registry.releaseSelection(selection)
            return await finishWithoutExecution(
                envelope: envelope,
                result: Self.policyFailure(
                    decision: postConfirmationPolicy,
                    requestID: requestID,
                    providerID: selection.providerID
                )
            )
        }
        await telemetry.markAuthorized(
            requestID: requestID,
            policyRevision: postConfirmationPolicy.policyRevision
        )

        if let preparedIdempotency {
            do {
                let decision = try await idempotency.claim(
                    key: preparedIdempotency.key,
                    fingerprint: preparedIdempotency.fingerprint,
                    providerID: selection.providerID,
                    requestID: requestID,
                    retentionMilliseconds: preparedIdempotency.retentionMilliseconds,
                    maximumTerminalResultBytes:
                    preparedIdempotency.maximumTerminalResultBytes
                )
                guard case .execute = decision else {
                    await registry.releaseSelection(selection)
                    return await finishExistingIdempotency(
                        decision,
                        prepared: preparedIdempotency,
                        envelope: envelope
                    )
                }
            } catch {
                await registry.releaseSelection(selection)
                return await finishWithoutExecution(
                    envelope: envelope,
                    result: Self.failure(code: .internal, requestID: requestID)
                )
            }
        }

        let lease: ProviderLease
        do {
            lease = try await registry.acquire(selection)
        } catch let error as ProviderResolutionError {
            return await settleBeforeMailboxExecution(
                preparedIdempotency,
                envelope: envelope,
                result: Self.resolutionFailure(error, requestID: requestID),
                providerID: selection.providerID
            )
        } catch {
            return await settleBeforeMailboxExecution(
                preparedIdempotency,
                envelope: envelope,
                result: Self.failure(
                    code: .internal,
                    requestID: requestID,
                    providerID: selection.providerID
                ),
                providerID: selection.providerID
            )
        }

        do {
            try admitExecution(
                envelope: envelope,
                providerID: lease.providerID,
                generation: lease.generation,
                encodedBytes: accounting.encodedBytes,
                admissionClass: rule.admissionClass
            )
        } catch GlobalAdmissionFailure.cycle {
            await lease.release()
            return await settleBeforeMailboxExecution(
                preparedIdempotency,
                envelope: envelope,
                result: Self.failure(
                    code: .cycleDetected,
                    requestID: requestID,
                    providerID: lease.providerID
                ),
                providerID: lease.providerID
            )
        } catch {
            await lease.release()
            await telemetry.markAdmissionRejected(requestID: requestID)
            return await settleBeforeMailboxExecution(
                preparedIdempotency,
                envelope: envelope,
                result: Self.failure(
                    code: .overloaded,
                    retryable: true,
                    retryAfterMilliseconds: 25,
                    requestID: requestID,
                    providerID: lease.providerID
                ),
                providerID: lease.providerID
            )
        }

        await telemetry.markQueued(
            requestID: requestID,
            providerID: lease.providerID,
            generation: lease.generation
        )

        let telemetry = self.telemetry
        let progressSink = self.progressSink
        let progressMinimumInterval = limits.progressMinimumInterval
        let reporter = IntentProgressReporter(
            requestID: requestID,
            minimumInterval: progressMinimumInterval
        ) { notification in
            await telemetry.markProgress(requestID: notification.requestID)
            await progressSink(notification)
        }
        let idempotencyStore = self.idempotency
        let dispatcher = self
        let policy = self.policy
        let registry = self.registry
        let providerPrincipal = lease.principal
        let operation: IntentMailboxJob.Operation = {
            let executionPolicy = await policy.authorize(executionPolicyRequest)
            guard case .allowed = executionPolicy.verdict else {
                return .failure(Self.policyProviderFailure(executionPolicy))
            }
            await telemetry.markAuthorized(
                requestID: requestID,
                policyRevision: executionPolicy.policyRevision
            )
            await telemetry.markStarted(requestID: requestID)
            if let preparedIdempotency {
                do {
                    try await idempotencyStore.markRunning(
                        key: preparedIdempotency.key,
                        requestID: requestID
                    )
                } catch {
                    return .failure(
                        IntentProviderFailure(code: .kernel(.internal))
                    )
                }
            }

            let context = IntentProviderContext(
                requestID: requestID,
                authorizedFilesystemPaths:
                executionPolicy.authorizedFilesystemPaths,
                authorizedNetworkHosts:
                executionPolicy.authorizedNetworkHosts,
                nestedSend: { nestedRequest in
                    await dispatcher.sendFromProvider(
                        nestedRequest,
                        principal: providerPrincipal,
                        inheritedScope: envelope.scope,
                        causalContext: CausalContext(
                            traceID: envelope.traceID,
                            parentRequestID: envelope.requestID,
                            parentDeadline: envelope.deadline
                        )
                    )
                },
                progressSink: { progress in
                    await reporter.report(progress)
                }
            )
            do {
                try Task.checkCancellation()
                let reply = try await lease.binding.invoke(
                    envelope: envelope,
                    context: context
                )
                let validation = Self.validateProviderReply(
                    reply,
                    contract: contract,
                    valueLimits: rule.valueLimits
                )
                await registry.recordOutputValidation(
                    providerID: lease.providerID,
                    generation: lease.generation,
                    isValid: validation.isContractValid
                )
                return validation.reply
            } catch is CancellationError {
                return .failure(
                    IntentProviderFailure(code: .kernel(.cancelled))
                )
            } catch {
                return .failure(
                    IntentProviderFailure(code: .kernel(.handlerFailed))
                )
            }
        }

        let job: IntentMailboxJob
        do {
            job = try IntentMailboxJob(
                requestID: requestID,
                principal: request.caller,
                deadline: deadline,
                encodedBytes: accounting.encodedBytes,
                admissionClass: rule.admissionClass,
                operation: operation
            ) { completion in
                await lease.release()
                await dispatcher.releaseExecutionFromCompletion(requestID: requestID)
                await telemetry.markPhysicallyCompleted(
                    requestID: requestID,
                    completion: completion
                )
            }
        } catch {
            releaseExecution(requestID: requestID)
            await lease.release()
            await reporter.close()
            return await settleBeforeMailboxExecution(
                preparedIdempotency,
                envelope: envelope,
                result: Self.failure(code: .internal, requestID: requestID),
                providerID: lease.providerID
            )
        }

        let policyMonitor = Task { @concurrent [
            policy,
            mailbox = lease.mailbox,
            executionPolicyRequest
        ] in
            var revision = postConfirmationPolicy.policyRevision
            while !Task.isCancelled {
                do {
                    revision = try await policy.waitForRevision(after: revision)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                let decision = await policy.authorize(executionPolicyRequest)
                revision = decision.policyRevision
                guard case .allowed = decision.verdict else {
                    await mailbox.cancel(requestID: requestID)
                    return
                }
            }
        }
        defer { policyMonitor.cancel() }

        let terminal: IntentMailboxTerminal
        do {
            terminal = try await lease.mailbox.submit(job)
        } catch let error as IntentMailboxAdmissionError {
            releaseExecution(requestID: requestID)
            await lease.release()
            await reporter.close()
            await telemetry.markAdmissionRejected(requestID: requestID)
            let result = Self.mailboxAdmissionFailure(
                error,
                requestID: requestID,
                providerID: lease.providerID
            )
            return await settleBeforeMailboxExecution(
                preparedIdempotency,
                envelope: envelope,
                result: result,
                providerID: lease.providerID
            )
        } catch {
            releaseExecution(requestID: requestID)
            await lease.release()
            await reporter.close()
            let result = Self.failure(
                code: .internal,
                requestID: requestID,
                providerID: lease.providerID
            )
            return await settleBeforeMailboxExecution(
                preparedIdempotency,
                envelope: envelope,
                result: result,
                providerID: lease.providerID
            )
        }

        await reporter.close()
        let result = Self.result(
            from: terminal,
            requestID: requestID,
            providerID: lease.providerID
        )
        return await settlePreparedIdempotency(
            preparedIdempotency,
            envelope: envelope,
            result: result,
            providerID: lease.providerID
        )
    }

    /// The confirmation a contract actually demands from this caller.
    ///
    /// `.policy` means standing consent: the person answers once for a caller and a
    /// contract, and the answer is remembered. That is the right shape when the authority
    /// being granted is the *kind* of operation — may this plugin write to the terminal.
    /// It is the wrong shape for a delegable (`open`-class) contract asked by an agent,
    /// because there the danger is the payload rather than the kind, and an agent's payload
    /// can be written by whatever it just read. One approval would otherwise become
    /// permission to open anything, forever, from any page the agent is pointed at.
    ///
    /// Pure, so the rule is asserted without a kernel. See `docs/design-open-handlers.md`.
    static func effectiveConfirmation(
        contract: IntentContract,
        caller: IntentPrincipal
    ) -> IntentConfirmation {
        guard contract.effects.confirmation == .policy,
              caller.audience == .agent,
              contract.contractClass == .open
        else {
            return contract.effects.confirmation
        }
        return .always
    }

    private func resolveCallerConsent(
        key: CallerConsentKey,
        confirmationRequest: IntentConfirmationRequest,
        deadline: ContinuousClock.Instant
    ) async -> CallerConsentWaveOutcome {
        let waiterID = UUID()
        // A confirmation nobody answers must not hold the request open forever (invariant 10).
        // The caller already stated a deadline and the dispatcher already refuses past it —
        // but that check ran *after* this wait, so it could never fire on a wait that only
        // ended when someone answered.
        //
        // Expiry leaves through the same door cancellation uses. That is deliberate: the
        // waiter is removed by `removeValue`, so whichever of expiry, cancellation and the
        // authorizer arrives first settles the continuation exactly once, and a flight that
        // still has waiters keeps its prompt standing — one caller's deadline must not take
        // the dialog away from another caller who is still waiting on it.
        let expiry = Task { [weak self] in
            try? await ContinuousClock().sleep(until: deadline)
            guard !Task.isCancelled else { return }
            await self?.cancelCallerConsentWaiter(
                waiterID: waiterID,
                key: key
            )
        }
        defer { expiry.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                registerCallerConsentWaiter(
                    waiterID: waiterID,
                    key: key,
                    confirmationRequest: confirmationRequest,
                    continuation: continuation
                )
                if Task.isCancelled {
                    cancelCallerConsentWaiter(
                        waiterID: waiterID,
                        key: key
                    )
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelCallerConsentWaiter(
                    waiterID: waiterID,
                    key: key
                )
            }
        }
    }

    func callerConsentWaiterCount(for key: CallerConsentKey) -> Int {
        callerConsentFlights[key]?.waiters.count ?? 0
    }

    private func registerCallerConsentWaiter(
        waiterID: UUID,
        key: CallerConsentKey,
        confirmationRequest: IntentConfirmationRequest,
        continuation: CheckedContinuation<CallerConsentWaveOutcome, Never>
    ) {
        if var flight = callerConsentFlights[key] {
            flight.waiters[waiterID] = continuation
            callerConsentFlights[key] = flight
            return
        }

        let flightID = UUID()
        let grantFence = CallerConsentGrantFence()
        let policy = self.policy
        let confirmationAuthorizer = self.confirmationAuthorizer
        let task = Task { @concurrent [
            weak self,
            policy,
            confirmationAuthorizer,
            key,
            confirmationRequest,
            flightID
        ] in
            let authorization: CallerConsentAuthorization
            if await policy.hasStandingConsent(
                contract: key.contract,
                caller: confirmationRequest.envelope.caller
            ) {
                authorization = .standingConsent
            } else {
                let confirmation = await confirmationAuthorizer.authorize(
                    confirmationRequest
                )
                authorization = confirmation == .approved
                    ? .approved
                    : .denied
            }
            guard !Task.isCancelled else { return }
            await self?.completeCallerConsentFlight(
                key: key,
                flightID: flightID,
                authorization: authorization
            )
        }
        callerConsentFlights[key] = CallerConsentFlight(
            id: flightID,
            task: task,
            grantFence: grantFence,
            waiters: [waiterID: continuation]
        )
    }

    private func cancelCallerConsentWaiter(
        waiterID: UUID,
        key: CallerConsentKey
    ) {
        guard var flight = callerConsentFlights[key],
              let continuation = flight.waiters.removeValue(
                  forKey: waiterID
              )
        else {
            return
        }

        if flight.waiters.isEmpty {
            flight.grantFence.invalidate()
            callerConsentFlights[key] = nil
            flight.task.cancel()
        } else {
            callerConsentFlights[key] = flight
        }
        continuation.resume(returning: .cancelled)
    }

    private func completeCallerConsentFlight(
        key: CallerConsentKey,
        flightID: UUID,
        authorization: CallerConsentAuthorization
    ) async {
        guard let flight = callerConsentFlights[key],
              flight.id == flightID,
              !flight.waiters.isEmpty
        else {
            return
        }

        let outcome: CallerConsentWaveOutcome
        switch authorization {
        case .standingConsent:
            outcome = .approved
        case .denied:
            outcome = .denied
        case .approved:
            do {
                let didPersist = try await callerConsentPersistence(
                    key,
                    flight.grantFence
                )
                outcome = didPersist ? .approved : .cancelled
            } catch {
                outcome = .persistenceFailed
            }
        }

        guard let completedFlight = callerConsentFlights[key],
              completedFlight.id == flightID
        else {
            return
        }
        callerConsentFlights[key] = nil
        for continuation in completedFlight.waiters.values {
            continuation.resume(returning: outcome)
        }
    }

    private func finishExistingIdempotency(
        _ decision: IntentIdempotencyDecision,
        prepared: PreparedIdempotency,
        envelope: IntentEnvelope
    ) async -> IntentResult {
        let result: IntentResult
        switch decision {
        case let .replay(replayed):
            result = replayed
        case let .join(requestID, providerID):
            result = await Self.waitForJoinedResult(
                store: idempotency,
                key: prepared.key,
                joinedRequestID: requestID,
                envelope: envelope,
                providerID: providerID
            )
        case let .conflict(_, providerID):
            result = Self.failure(
                code: .idempotencyConflict,
                requestID: envelope.requestID,
                providerID: providerID
            )
        case .execute:
            result = Self.failure(code: .internal, requestID: envelope.requestID)
        }
        return await finishWithoutExecution(envelope: envelope, result: result)
    }

    private func settlePreparedIdempotency(
        _ prepared: PreparedIdempotency?,
        envelope: IntentEnvelope,
        result: IntentResult,
        providerID: ProviderID
    ) async -> IntentResult {
        var finalResult = result
        if let prepared {
            do {
                try await idempotency.settle(
                    key: prepared.key,
                    requestID: envelope.requestID,
                    result: result
                )
            } catch {
                finalResult = Self.failure(
                    code: .internal,
                    details: .object(["reason": .string("idempotency-persistence-failed")]),
                    outcome: .unknown,
                    requestID: envelope.requestID,
                    providerID: providerID
                )
            }
        }
        let outputBytes = Self.outputBytes(finalResult)
        await telemetry.markSettled(
            requestID: envelope.requestID,
            result: finalResult,
            outputBytes: outputBytes
        )
        return finalResult
    }

    private func settleBeforeMailboxExecution(
        _ prepared: PreparedIdempotency?,
        envelope: IntentEnvelope,
        result: IntentResult,
        providerID: ProviderID
    ) async -> IntentResult {
        let settled = await settlePreparedIdempotency(
            prepared,
            envelope: envelope,
            result: result,
            providerID: providerID
        )
        await telemetry.markPhysicallyCompleted(
            requestID: envelope.requestID,
            completion: nil
        )
        return settled
    }

    private func sendFromProvider(
        _ request: IntentProviderSendRequest,
        principal: IntentPrincipal,
        inheritedScope: InvocationScope,
        causalContext: CausalContext
    ) async -> IntentResult {
        await send(
            IntentDispatchRequest(
                intentID: request.intentID,
                input: request.input,
                caller: principal,
                scope: request.scopeOverride?.applying(to: inheritedScope)
                    ?? inheritedScope,
                target: request.target,
                idempotencyKey: request.idempotencyKey,
                requestedTimeout: request.requestedTimeout
            ),
            causalContext: causalContext
        )
    }

    private func finishWithoutExecution(
        envelope: IntentEnvelope,
        result: IntentResult
    ) async -> IntentResult {
        await telemetry.markSettled(
            requestID: envelope.requestID,
            result: result,
            outputBytes: Self.outputBytes(result)
        )
        await telemetry.markPhysicallyCompleted(
            requestID: envelope.requestID,
            completion: nil
        )
        return result
    }

    private func admitExecution(
        envelope: IntentEnvelope,
        providerID: ProviderID,
        generation: UInt64,
        encodedBytes: Int,
        admissionClass: IntentAdmissionClass
    ) throws {
        let principalUsage = usageByPrincipal[envelope.caller] ?? Usage()
        guard usage.requests + 1 <= limits.maxInFlightRequests,
              usage.bytes + encodedBytes <= limits.maxInFlightEncodedBytes,
              principalUsage.requests + 1 <= limits.maxInFlightPerPrincipal
        else {
            throw GlobalAdmissionFailure.overloaded
        }
        if admissionClass == .background {
            guard backgroundUsage.requests + 1
                <= limits.maxInFlightRequests - limits.reservedInteractiveRequests,
                backgroundUsage.bytes + encodedBytes
                <= limits.maxInFlightEncodedBytes - limits.reservedInteractiveBytes
            else {
                throw GlobalAdmissionFailure.overloaded
            }
        }

        let node = ProviderNode(providerID: providerID, generation: generation)
        let parentReservation = envelope.parentRequestID.flatMap { reservations[$0] }
        if let parentNode = parentReservation?.node {
            if parentNode == node || hasPath(from: node, to: parentNode) {
                throw GlobalAdmissionFailure.cycle
            }
        }

        var depth = 0
        var cursor = envelope.parentRequestID
        while let requestID = cursor, let reservation = reservations[requestID] {
            depth += 1
            guard depth < limits.maximumCausalDepth else {
                throw GlobalAdmissionFailure.cycle
            }
            cursor = reservation.parentRequestID
        }

        let reservation = ExecutionReservation(
            requestID: envelope.requestID,
            parentRequestID: envelope.parentRequestID,
            principal: envelope.caller,
            encodedBytes: encodedBytes,
            admissionClass: admissionClass,
            node: node,
            parentNode: parentReservation?.node
        )
        reservations[envelope.requestID] = reservation
        usage.requests += 1
        usage.bytes += encodedBytes
        usageByPrincipal[envelope.caller, default: Usage()].requests += 1
        usageByPrincipal[envelope.caller, default: Usage()].bytes += encodedBytes
        if admissionClass == .background {
            backgroundUsage.requests += 1
            backgroundUsage.bytes += encodedBytes
        }
        if let parentNode = reservation.parentNode {
            waitEdges[parentNode, default: [:]][node, default: 0] += 1
        }
    }

    private func releaseExecutionFromCompletion(requestID: UUID) {
        releaseExecution(requestID: requestID)
    }

    private func beginConfigurationMutation() throws {
        guard !configurationMutationInProgress else {
            throw IntentDispatcherError.configurationBusy
        }
        configurationMutationInProgress = true
    }

    private func releaseConfigurationMutation() {
        configurationMutationInProgress = false
    }

    private func releaseExecution(requestID: UUID) {
        guard let reservation = reservations.removeValue(forKey: requestID) else { return }
        usage.requests -= 1
        usage.bytes -= reservation.encodedBytes

        if var principalUsage = usageByPrincipal[reservation.principal] {
            principalUsage.requests -= 1
            principalUsage.bytes -= reservation.encodedBytes
            usageByPrincipal[reservation.principal] =
                principalUsage.requests == 0 ? nil : principalUsage
        }
        if reservation.admissionClass == .background {
            backgroundUsage.requests -= 1
            backgroundUsage.bytes -= reservation.encodedBytes
        }
        if let parentNode = reservation.parentNode,
           var children = waitEdges[parentNode],
           let count = children[reservation.node]
        {
            if count == 1 {
                children[reservation.node] = nil
            } else {
                children[reservation.node] = count - 1
            }
            waitEdges[parentNode] = children.isEmpty ? nil : children
        }
    }

    private func hasPath(from start: ProviderNode, to target: ProviderNode) -> Bool {
        var pending = [start]
        var visited: Set<ProviderNode> = []
        while let node = pending.popLast() {
            guard visited.insert(node).inserted else { continue }
            if node == target {
                return true
            }
            pending.append(contentsOf: waitEdges[node]?.keys ?? [:].keys)
        }
        return false
    }
}

private extension IntentDispatcher {
    private static func prepareIdempotency(
        contract: IntentContract,
        envelope: IntentEnvelope,
        limits: IntentValueLimits
    ) throws -> PreparedIdempotency? {
        switch contract.effects.idempotency {
        case .none:
            guard envelope.idempotencyKey == nil else {
                throw IntentIdempotencyError.invalidKey
            }
            return nil
        case .keyed:
            guard let key = envelope.idempotencyKey,
                  let retention = contract.effects.retentionMilliseconds
            else {
                throw IntentIdempotencyError.invalidKey
            }
            return PreparedIdempotency(
                key: try IntentIdempotencyClaimKey(
                    principal: envelope.caller,
                    intentID: envelope.name,
                    key: key
                ),
                fingerprint: IntentIdempotencyFingerprint(
                    inputDigest: try envelope.input.canonicalSHA256Digest(limits: limits),
                    explicitTarget: envelope.target
                ),
                retentionMilliseconds: retention,
                maximumTerminalResultBytes: min(
                    limits.maxEncodedBytes + 4_096,
                    IntentIdempotencyLimits.hardMaximumTerminalResultBytes
                )
            )
        }
    }

    static func consentRequirement(
        rule: IntentDispatchRule,
        contract: IntentContract,
        selection: ProviderSelection
    ) -> ProviderConsentRequirement {
        let requiresConsent: Bool
        switch rule.providerConsent {
        case .never:
            requiresConsent = false
        case .always:
            requiresConsent = true
        case .nonTrustedProvider:
            requiresConsent = rule.trustedDefault != selection.providerID
        }
        guard requiresConsent else { return .notRequired }
        return .required(
            ProviderConsentKey(
                contract: contract.name,
                providerID: selection.providerID,
                policyFingerprint: selection.policyFingerprint
            )
        )
    }

    private static func validateProviderReply(
        _ reply: IntentProviderReply,
        contract: IntentContract,
        valueLimits: IntentValueLimits
    ) -> ProviderReplyValidation {
        switch reply {
        case let .success(value):
            do {
                try value.validate(limits: valueLimits)
                let validation = try contract.validateOutput(value)
                guard validation.isValid else {
                    return ProviderReplyValidation(
                        reply: .failure(
                            IntentProviderFailure(
                                code: .kernel(.invalidOutput),
                                details: validationDetails(validation.issues)
                            )
                        ),
                        isContractValid: false
                    )
                }
                return ProviderReplyValidation(reply: reply, isContractValid: true)
            } catch {
                return ProviderReplyValidation(
                    reply: .failure(
                        IntentProviderFailure(code: .kernel(.invalidOutput))
                    ),
                    isContractValid: false
                )
            }
        case let .failure(failure):
            if let details = failure.details {
                do {
                    try details.validate(limits: valueLimits)
                } catch {
                    return ProviderReplyValidation(
                        reply: .failure(
                            IntentProviderFailure(code: .kernel(.handlerFailed))
                        ),
                        isContractValid: false
                    )
                }
            }
            switch failure.code {
            case let .domain(code):
                return ProviderReplyValidation(
                    reply: contract.domainErrors.contains(code)
                        ? reply
                        : .failure(IntentProviderFailure(code: .kernel(.handlerFailed))),
                    isContractValid: contract.domainErrors.contains(code)
                )
            case let .kernel(code):
                let allowed: Set<IntentKernelErrorCode> = [
                    .cancelled,
                    .deadlineExceeded,
                    .providerRetired,
                    .handlerFailed,
                    .invalidOutput,
                ]
                return ProviderReplyValidation(
                    reply: allowed.contains(code)
                        ? reply
                        : .failure(IntentProviderFailure(code: .kernel(.handlerFailed))),
                    isContractValid: allowed.contains(code)
                )
            }
        }
    }

    static func result(
        from terminal: IntentMailboxTerminal,
        requestID: UUID,
        providerID: ProviderID
    ) -> IntentResult {
        switch terminal {
        case let .reply(.success(value)):
            return .success(value: value, requestID: requestID, providerID: providerID)
        case let .reply(.failure(failure)):
            return .failure(
                error: IntentError(
                    code: failure.code,
                    details: failure.details,
                    retryable: failure.retryable,
                    retryAfterMilliseconds: failure.retryAfterMilliseconds,
                    outcome: .unknown
                ),
                requestID: requestID,
                providerID: providerID
            )
        case let .cancelled(outcome):
            return failure(
                code: .cancelled,
                outcome: outcome,
                requestID: requestID,
                providerID: providerID
            )
        case let .deadlineExceeded(outcome):
            return failure(
                code: .deadlineExceeded,
                outcome: outcome,
                requestID: requestID,
                providerID: providerID
            )
        case let .providerRetired(outcome):
            return failure(
                code: .providerRetired,
                outcome: outcome,
                requestID: requestID,
                providerID: providerID
            )
        }
    }

    static func waitForJoinedResult(
        store: IntentIdempotencyStore,
        key: IntentIdempotencyClaimKey,
        joinedRequestID: UUID,
        envelope: IntentEnvelope,
        providerID: ProviderID
    ) async -> IntentResult {
        do {
            return try await withThrowingTaskGroup(of: IntentResult.self) { group in
                group.addTask {
                    try await store.waitForResult(
                        key: key,
                        requestID: joinedRequestID
                    )
                }
                group.addTask {
                    try await ContinuousClock().sleep(until: envelope.deadline)
                    return failure(
                        code: .deadlineExceeded,
                        outcome: .unknown,
                        requestID: envelope.requestID,
                        providerID: providerID
                    )
                }
                guard let first = try await group.next() else {
                    return failure(code: .internal, requestID: envelope.requestID)
                }
                group.cancelAll()
                return first
            }
        } catch is CancellationError {
            return failure(
                code: .cancelled,
                outcome: .unknown,
                requestID: envelope.requestID,
                providerID: providerID
            )
        } catch {
            return failure(
                code: .internal,
                requestID: envelope.requestID,
                providerID: providerID
            )
        }
    }

    static func failure(
        code: IntentKernelErrorCode,
        details: IntentValue? = nil,
        retryable: Bool = false,
        retryAfterMilliseconds: UInt64? = nil,
        outcome: IntentOutcome = .notStarted,
        requestID: UUID,
        providerID: ProviderID? = nil
    ) -> IntentResult {
        .failure(
            error: IntentError(
                code: .kernel(code),
                details: details,
                retryable: retryable,
                retryAfterMilliseconds: retryAfterMilliseconds,
                outcome: outcome
            ),
            requestID: requestID,
            providerID: providerID
        )
    }

    static func policyFailure(
        decision: PolicyDecision,
        requestID: UUID,
        providerID: ProviderID? = nil
    ) -> IntentResult {
        guard case let .denied(reason) = decision.verdict else {
            return failure(code: .internal, requestID: requestID)
        }
        let code: IntentKernelErrorCode
        if case .undeclaredUse = reason {
            code = .undeclaredUse
        } else {
            code = .denied
        }
        return failure(
            code: code,
            details: policyDetails(reason),
            requestID: requestID,
            providerID: providerID
        )
    }

    static func policyProviderFailure(
        _ decision: PolicyDecision
    ) -> IntentProviderFailure {
        guard case let .denied(reason) = decision.verdict else {
            return IntentProviderFailure(code: .kernel(.internal))
        }
        let code: IntentKernelErrorCode
        if case .undeclaredUse = reason {
            code = .undeclaredUse
        } else {
            code = .denied
        }
        return IntentProviderFailure(
            code: .kernel(code),
            details: policyDetails(reason)
        )
    }

    static func policyDetails(_ reason: PolicyDenialReason) -> IntentValue {
        let name: String
        switch reason {
        case .undeclaredUse:
            name = "undeclared-use"
        case .intentNotDiscoverable:
            name = "intent-not-discoverable"
        case .audienceCannotInvoke:
            name = "audience-cannot-invoke"
        case .missingCapability:
            name = "missing-capability"
        case .workspaceRequired:
            name = "workspace-required"
        case .workspaceOutsideGrant:
            name = "workspace-outside-grant"
        case .paneRequired:
            name = "pane-required"
        case .paneOutsideGrant:
            name = "pane-outside-grant"
        case .invalidFilesystemPath:
            name = "invalid-filesystem-path"
        case .filesystemPathOutsideGrant:
            name = "filesystem-path-outside-grant"
        case .invalidNetworkHost:
            name = "invalid-network-host"
        case .networkHostOutsideGrant:
            name = "network-host-outside-grant"
        case .providerConsentContractMismatch:
            name = "provider-consent-contract-mismatch"
        case .providerConsentProviderMismatch:
            name = "provider-consent-provider-mismatch"
        case .providerConsentRequired:
            name = "provider-consent-required"
        case .providerConsentDenied:
            name = "provider-consent-denied"
        case .providerConsentStale:
            name = "provider-consent-stale"
        case .callerConsentContractMismatch:
            name = "caller-consent-contract-mismatch"
        case .callerConsentCallerMismatch:
            name = "caller-consent-caller-mismatch"
        case .callerConsentRequired:
            name = "caller-consent-required"
        }
        return .object(["reason": .string(name)])
    }

    static func resolutionFailure(
        _ error: ProviderResolutionError,
        requestID: UUID
    ) -> IntentResult {
        switch error {
        case .noProvider:
            return failure(code: .noProvider, requestID: requestID)
        case let .ambiguousProvider(_, candidates):
            return failure(
                code: .ambiguousProvider,
                details: .object([
                    "candidates": .array(candidates.map { .string($0.rawValue) }),
                ]),
                requestID: requestID
            )
        case let .providerUnavailable(_, providerID):
            return failure(
                code: .providerUnavailable,
                requestID: requestID,
                providerID: providerID
            )
        }
    }

    static func mailboxAdmissionFailure(
        _ error: IntentMailboxAdmissionError,
        requestID: UUID,
        providerID: ProviderID
    ) -> IntentResult {
        switch error {
        case let .overloaded(retryAfter), let .principalQuotaExceeded(retryAfter):
            return failure(
                code: .overloaded,
                retryable: true,
                retryAfterMilliseconds: retryAfter,
                requestID: requestID,
                providerID: providerID
            )
        case .retired:
            return failure(
                code: .providerUnavailable,
                requestID: requestID,
                providerID: providerID
            )
        case .duplicateRequestID, .requestTooLarge:
            return failure(
                code: .internal,
                requestID: requestID,
                providerID: providerID
            )
        }
    }

    static func validationDetails(
        _ issues: [IntentContractValidationIssue]
    ) -> IntentValue {
        .object([
            "issues": .array(
                issues.map { issue in
                    .object([
                        "location": .string(issue.location.rawValue),
                        "path": .string(issue.instancePath),
                        "schemaPath": .string(issue.schemaPath),
                        "keyword": .string(issue.keyword),
                    ])
                }
            ),
        ])
    }

    static func outputBytes(_ result: IntentResult) -> Int? {
        switch result {
        case let .success(success):
            return try? success.value.accounting().encodedBytes
        case let .failure(failure):
            return try? failure.error.details?.accounting().encodedBytes
        }
    }
}
