import Foundation

public struct ProviderRegistryRevision: Sendable, Equatable, Hashable, Codable, Comparable {
    public static let zero = ProviderRegistryRevision(0)

    private let words: [UInt64]

    public init(_ value: UInt64) {
        words = [value]
    }

    private init(words: [UInt64]) {
        self.words = words
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decoded = try container.decode([UInt64].self)
        guard !decoded.isEmpty,
              decoded.count == 1 || decoded.last != 0
        else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "provider registry revision is not normalized"
            )
        }
        words = decoded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(words)
    }

    public static func < (
        lhs: ProviderRegistryRevision,
        rhs: ProviderRegistryRevision
    ) -> Bool {
        guard lhs.words.count == rhs.words.count else {
            return lhs.words.count < rhs.words.count
        }
        for (left, right) in zip(lhs.words.reversed(), rhs.words.reversed())
        where left != right {
            return left < right
        }
        return false
    }

    fileprivate func incremented() -> ProviderRegistryRevision {
        var next = words
        for index in next.indices {
            if next[index] < UInt64.max {
                next[index] += 1
                return ProviderRegistryRevision(words: next)
            }
            next[index] = 0
        }
        next.append(1)
        return ProviderRegistryRevision(words: next)
    }
}

public enum ProviderLifecycle: String, Sendable, Equatable, Codable {
    case staging
    case active
    case draining
    case retired
    case failed
    case disabled
}

public enum ProviderRegistryError: Error, Sendable, Equatable {
    case ownerMismatch(providerID: ProviderID)
    case generationOutOfSequence(expected: UInt64, actual: UInt64)
    case generationSuperseded(providerID: ProviderID, generation: UInt64, latest: UInt64)
    case generationNotFound(providerID: ProviderID, generation: UInt64)
    case generationNotStaging(providerID: ProviderID, generation: UInt64)
    case providerNotFound(ProviderID)
    case generationOverflow(ProviderID)
}

public enum ProviderResolutionError: Error, Sendable, Equatable {
    case noProvider(IntentID)
    case ambiguousProvider(intentID: IntentID, candidates: [ProviderID])
    case providerUnavailable(intentID: IntentID, providerID: ProviderID)
}

public struct ProviderGenerationSnapshot: Sendable, Equatable {
    public let providerID: ProviderID
    public let owner: IntentProviderOwner
    public let principal: IntentPrincipal
    public let generation: UInt64
    public let lifecycle: ProviderLifecycle
    public let intentIDs: [IntentID]
    public let exportedIntentIDs: [IntentID]
    public let policyFingerprint: PolicyFingerprint
    public let selectionCount: Int
    public let leaseCount: Int
    public let isHealthy: Bool
    public let failure: String?
}

public struct ProviderRegistrySnapshot: Sendable, Equatable {
    public let revision: ProviderRegistryRevision
    public let generations: [ProviderGenerationSnapshot]
    public let configuredDefaults: [IntentID: ProviderID]
    public let residentGenerations: Int
    public let retiredHistoryEntries: Int
}

public struct ProviderResolutionRequest: Sendable, Equatable {
    public let intentID: IntentID
    public let explicitTarget: ProviderID?
    public let trustedDefault: ProviderID?
    public let allowsAutomaticSelection: Bool

    public init(
        intentID: IntentID,
        explicitTarget: ProviderID? = nil,
        trustedDefault: ProviderID? = nil,
        allowsAutomaticSelection: Bool = false
    ) {
        self.intentID = intentID
        self.explicitTarget = explicitTarget
        self.trustedDefault = trustedDefault
        self.allowsAutomaticSelection = allowsAutomaticSelection
    }
}

/// Who would serve a contract, and why they won — or that nobody can win until a person
/// says so. Asking this question runs no provider code and takes no right to run any, so a
/// caller may branch on the answer without holding the authority to act on it.
///
/// Separating the question from the dispatch is what lets a host serve a trusted-default
/// answer with its own typed implementation and no bus traffic, and what turns two eligible
/// handlers into a chooser rather than a thrown error. See `docs/design-open-handlers.md`.
public enum ProviderResolutionDecision: Sendable, Equatable {
    /// The caller named this provider and it is eligible.
    case explicitTarget(ProviderID)
    /// The person configured this provider as the handler for the contract.
    case configuredDefault(ProviderID)
    /// Nothing was configured, so the built-in handler serves it.
    case trustedDefault(ProviderID)
    /// Exactly one provider is eligible and the contract allows taking it unasked.
    case onlyEligible(ProviderID)
    /// More than one provider could serve this and nothing has been chosen. Candidates are
    /// sorted so a chooser presents them in a stable order.
    case needsChoice([ProviderID])
    /// The caller named a provider that is not eligible.
    case targetUnavailable(ProviderID)
    /// Nothing can serve this contract.
    case noProvider

    /// The provider that would run, or nil when the answer needs a person or nobody
    /// qualifies.
    public var providerID: ProviderID? {
        switch self {
        case let .explicitTarget(providerID),
             let .configuredDefault(providerID),
             let .trustedDefault(providerID),
             let .onlyEligible(providerID):
            providerID
        case .needsChoice, .targetUnavailable, .noProvider:
            nil
        }
    }

    /// Whether the built-in handler is the one that would run. A host serving this answer
    /// calls its own typed implementation instead of dispatching.
    public var isTrustedDefault: Bool {
        if case .trustedDefault = self { return true }
        return false
    }
}

public struct ProviderSelection: Sendable, Equatable {
    public let intentID: IntentID
    public let providerID: ProviderID
    public let owner: IntentProviderOwner
    public let principal: IntentPrincipal
    public let generation: UInt64
    public let policyFingerprint: PolicyFingerprint
    fileprivate let identity: UUID
    fileprivate let reservationID: UUID
}

public struct ProviderLease: Sendable {
    public let providerID: ProviderID
    public let owner: IntentProviderOwner
    public let principal: IntentPrincipal
    public let generation: UInt64
    public let policyFingerprint: PolicyFingerprint
    public let binding: IntentProviderBinding
    public let mailbox: IntentMailbox
    private let token: ProviderLeaseToken

    fileprivate init(
        providerID: ProviderID,
        owner: IntentProviderOwner,
        principal: IntentPrincipal,
        generation: UInt64,
        policyFingerprint: PolicyFingerprint,
        binding: IntentProviderBinding,
        mailbox: IntentMailbox,
        token: ProviderLeaseToken
    ) {
        self.providerID = providerID
        self.owner = owner
        self.principal = principal
        self.generation = generation
        self.policyFingerprint = policyFingerprint
        self.binding = binding
        self.mailbox = mailbox
        self.token = token
    }

    public func release() async {
        await token.release()
    }
}

private actor ProviderLeaseToken {
    private var isReleased = false
    private let releaseOperation: @Sendable () async -> Void

    init(releaseOperation: @escaping @Sendable () async -> Void) {
        self.releaseOperation = releaseOperation
    }

    func release() async {
        guard !isReleased else { return }
        isReleased = true
        await releaseOperation()
    }
}

public actor ProviderRegistry {
    private struct GenerationKey: Sendable, Hashable {
        let providerID: ProviderID
        let generation: UInt64
        let identity: UUID
    }

    private struct GenerationLookupKey: Sendable, Hashable {
        let providerID: ProviderID
        let generation: UInt64
    }

    private struct StoredGeneration: Sendable {
        let candidate: ProviderGenerationCandidate
        var lifecycle: ProviderLifecycle
        var selectionCount: Int
        var leaseCount: Int
        var consecutiveInvalidOutputs: Int
        var isHealthy: Bool
        var failure: String?
        var drainTask: Task<Void, Never>?
    }

    private var generations: [GenerationKey: StoredGeneration] = [:]
    private var generationKeys: [GenerationLookupKey: GenerationKey] = [:]
    private var selectionReservations: [UUID: GenerationKey] = [:]
    private var owners: [ProviderID: IntentProviderOwner] = [:]
    private var maximumGeneration: [ProviderID: UInt64] = [:]
    private var activeRoutes: [IntentID: [ProviderID: GenerationKey]] = [:]
    private var configuredDefaults: [IntentID: ProviderID] = [:]
    private var retirementReasons: [GenerationKey: ProviderRetirementReason] = [:]
    private var mailboxWaitKeys: Set<GenerationKey> = []
    private var mailboxIdleKeys: Set<GenerationKey> = []
    private var shutdownKeys: Set<GenerationKey> = []
    private var retiredHistory: [ProviderGenerationSnapshot] = []
    private var revision: ProviderRegistryRevision = .zero
    private let retiredHistoryLimit = 64
    private let invalidOutputQuarantineThreshold = 3

    public init() {}

    init(initialRevisionForTesting: ProviderRegistryRevision) {
        revision = initialRevisionForTesting
    }

    public func nextGeneration(for providerID: ProviderID) throws -> UInt64 {
        let current = maximumGeneration[providerID] ?? 0
        guard current < UInt64.max else {
            throw ProviderRegistryError.generationOverflow(providerID)
        }
        return current + 1
    }

    func stage(_ candidate: ProviderGenerationCandidate) throws {
        if let owner = owners[candidate.providerID], owner != candidate.owner {
            throw ProviderRegistryError.ownerMismatch(providerID: candidate.providerID)
        }

        let expected = try nextGeneration(for: candidate.providerID)
        guard candidate.generation == expected else {
            throw ProviderRegistryError.generationOutOfSequence(
                expected: expected,
                actual: candidate.generation
            )
        }

        let key = GenerationKey(
            providerID: candidate.providerID,
            generation: candidate.generation,
            identity: UUID()
        )
        let lookupKey = GenerationLookupKey(
            providerID: candidate.providerID,
            generation: candidate.generation
        )
        let supersededKeys: [GenerationKey] = generations.compactMap {
            existingKey, stored -> GenerationKey? in
            guard existingKey.providerID == candidate.providerID,
                  stored.lifecycle == .staging
            else {
                return nil
            }
            return existingKey
        }
        for supersededKey in supersededKeys {
            guard var superseded = generations[supersededKey] else { continue }
            superseded.lifecycle = .failed
            superseded.isHealthy = false
            superseded.failure = "superseded by generation \(candidate.generation)"
            generations[supersededKey] = superseded
            requestRetirement(supersededKey, reason: .stagingFailed)
        }
        generations[key] = StoredGeneration(
            candidate: candidate,
            lifecycle: .staging,
            selectionCount: 0,
            leaseCount: 0,
            consecutiveInvalidOutputs: 0,
            isHealthy: true,
            failure: nil,
            drainTask: nil
        )
        generationKeys[lookupKey] = key
        owners[candidate.providerID] = candidate.owner
        maximumGeneration[candidate.providerID] = candidate.generation
        advanceRevision()
    }

    public func activate(providerID: ProviderID, generation: UInt64) throws {
        guard let key = generationKey(providerID: providerID, generation: generation) else {
            throw ProviderRegistryError.generationNotFound(
                providerID: providerID,
                generation: generation
            )
        }
        guard var candidate = generations[key] else {
            throw ProviderRegistryError.generationNotFound(
                providerID: providerID,
                generation: generation
            )
        }
        let latest = maximumGeneration[providerID] ?? generation
        guard generation == latest else {
            throw ProviderRegistryError.generationSuperseded(
                providerID: providerID,
                generation: generation,
                latest: latest
            )
        }
        guard candidate.lifecycle == .staging else {
            throw ProviderRegistryError.generationNotStaging(
                providerID: providerID,
                generation: generation
            )
        }

        let previousKeys = generations.compactMap { existingKey, stored -> GenerationKey? in
            guard existingKey.providerID == providerID,
                  existingKey != key,
                  stored.lifecycle == .active
            else {
                return nil
            }
            return existingKey
        }

        removeActiveRoutes(for: providerID)
        for previousKey in previousKeys {
            beginDraining(previousKey)
        }

        candidate.lifecycle = .active
        candidate.failure = nil
        generations[key] = candidate
        for intentID in candidate.candidate.bindings.keys {
            activeRoutes[intentID, default: [:]][providerID] = key
        }
        advanceRevision()
    }

    public func failStaging(
        providerID: ProviderID,
        generation: UInt64,
        diagnostic: String
    ) throws {
        guard let key = generationKey(providerID: providerID, generation: generation) else {
            throw ProviderRegistryError.generationNotFound(
                providerID: providerID,
                generation: generation
            )
        }
        guard var stored = generations[key] else {
            throw ProviderRegistryError.generationNotFound(
                providerID: providerID,
                generation: generation
            )
        }
        guard stored.lifecycle == .staging else {
            throw ProviderRegistryError.generationNotStaging(
                providerID: providerID,
                generation: generation
            )
        }
        stored.lifecycle = .failed
        stored.isHealthy = false
        stored.failure = diagnostic
        generations[key] = stored
        advanceRevision()
        requestRetirement(key, reason: .stagingFailed)
    }

    public func setConfiguredDefault(
        _ providerID: ProviderID?,
        for intentID: IntentID
    ) throws {
        if let providerID, owners[providerID] == nil {
            throw ProviderRegistryError.providerNotFound(providerID)
        }

        if let providerID {
            guard configuredDefaults[intentID] != providerID else { return }
            configuredDefaults[intentID] = providerID
        } else {
            guard configuredDefaults.removeValue(forKey: intentID) != nil else { return }
        }
        advanceRevision()
    }

    public func setHealthy(
        _ isHealthy: Bool,
        providerID: ProviderID,
        generation: UInt64
    ) throws {
        guard let key = generationKey(providerID: providerID, generation: generation) else {
            throw ProviderRegistryError.generationNotFound(
                providerID: providerID,
                generation: generation
            )
        }
        guard var stored = generations[key] else {
            throw ProviderRegistryError.generationNotFound(
                providerID: providerID,
                generation: generation
            )
        }
        guard stored.isHealthy != isHealthy else { return }
        stored.isHealthy = isHealthy
        if isHealthy {
            stored.consecutiveInvalidOutputs = 0
        }
        generations[key] = stored
        advanceRevision()
    }

    func recordOutputValidation(
        providerID: ProviderID,
        generation: UInt64,
        isValid: Bool
    ) {
        guard let key = generationKey(providerID: providerID, generation: generation),
              var stored = generations[key],
              stored.lifecycle == .active || stored.lifecycle == .draining
        else {
            return
        }
        if isValid {
            stored.consecutiveInvalidOutputs = 0
            generations[key] = stored
            return
        }

        stored.consecutiveInvalidOutputs += 1
        if stored.consecutiveInvalidOutputs >= invalidOutputQuarantineThreshold,
           stored.isHealthy
        {
            stored.isHealthy = false
            generations[key] = stored
            advanceRevision()
        } else {
            generations[key] = stored
        }
    }

    /// Resolves a provider and holds its exact generation until `acquire` consumes the
    /// selection or `releaseSelection` abandons it.
    /// Asks who would serve `request`. Holds nothing, reserves nothing, and leaves the
    /// registry unchanged, so a caller can find out what would happen — and present a
    /// chooser, or run a built-in implementation directly — without taking the right to
    /// invoke anybody. `resolveAndHold` answers with the same rule, so a decision reported
    /// here is the one a dispatch would take.
    public func resolutionDecision(
        _ request: ProviderResolutionRequest
    ) -> ProviderResolutionDecision {
        decide(request: request, eligible: eligibleProviders(for: request))
    }

    public func resolveAndHold(
        _ request: ProviderResolutionRequest
    ) throws -> ProviderSelection {
        let eligibleByID = eligibleProviders(for: request)

        let selected: ProviderID
        switch decide(request: request, eligible: eligibleByID) {
        case let .explicitTarget(providerID),
             let .configuredDefault(providerID),
             let .trustedDefault(providerID),
             let .onlyEligible(providerID):
            selected = providerID
        case .targetUnavailable(let providerID):
            throw ProviderResolutionError.providerUnavailable(
                intentID: request.intentID,
                providerID: providerID
            )
        case .needsChoice(let candidates):
            throw ProviderResolutionError.ambiguousProvider(
                intentID: request.intentID,
                candidates: candidates
            )
        case .noProvider:
            throw ProviderResolutionError.noProvider(request.intentID)
        }

        guard let key = eligibleByID[selected],
              let stored = generations[key]
        else {
            throw ProviderResolutionError.providerUnavailable(
                intentID: request.intentID,
                providerID: selected
            )
        }

        let reservationID = UUID()
        var selectedGeneration = stored
        selectedGeneration.selectionCount += 1
        generations[key] = selectedGeneration
        selectionReservations[reservationID] = key

        return ProviderSelection(
            intentID: request.intentID,
            providerID: selected,
            owner: stored.candidate.owner,
            principal: stored.candidate.principal,
            generation: key.generation,
            policyFingerprint: stored.candidate.policyFingerprint,
            identity: key.identity,
            reservationID: reservationID
        )
    }

    /// The generations that could serve `request` right now. Eligibility is lifecycle,
    /// health, and export — a draining or quarantined handler is never an answer.
    private func eligibleProviders(
        for request: ProviderResolutionRequest
    ) -> [ProviderID: GenerationKey] {
        let routes = activeRoutes[request.intentID] ?? [:]
        return routes.reduce(into: [:]) { result, route in
            let (providerID, key) = route
            guard let stored = generations[key],
                  stored.lifecycle == .active,
                  stored.isHealthy,
                  stored.candidate.bindings[request.intentID]?.isExported == true
            else {
                return
            }
            result[providerID] = key
        }
    }

    /// The single ranking rule. Both the question and the dispatch go through here, so they
    /// cannot drift apart: a caller's explicit target, then the person's configured
    /// handler, then the built-in one, then a sole candidate the contract allows taking
    /// unasked — and otherwise a person has to choose.
    private func decide(
        request: ProviderResolutionRequest,
        eligible: [ProviderID: GenerationKey]
    ) -> ProviderResolutionDecision {
        if let explicitTarget = request.explicitTarget {
            return eligible[explicitTarget] != nil
                ? .explicitTarget(explicitTarget)
                : .targetUnavailable(explicitTarget)
        }
        if let configured = configuredDefaults[request.intentID],
           eligible[configured] != nil
        {
            return .configuredDefault(configured)
        }
        if let trustedDefault = request.trustedDefault,
           eligible[trustedDefault] != nil
        {
            return .trustedDefault(trustedDefault)
        }
        if eligible.count == 1, request.allowsAutomaticSelection,
           let only = eligible.keys.first
        {
            return .onlyEligible(only)
        }
        if eligible.isEmpty {
            return .noProvider
        }
        return .needsChoice(eligible.keys.sorted { $0.rawValue < $1.rawValue })
    }

    public func acquire(_ selection: ProviderSelection) throws -> ProviderLease {
        let key = GenerationKey(
            providerID: selection.providerID,
            generation: selection.generation,
            identity: selection.identity
        )
        guard selectionReservations.removeValue(forKey: selection.reservationID) == key,
              var stored = generations[key],
              stored.selectionCount > 0
        else {
            throw ProviderResolutionError.providerUnavailable(
                intentID: selection.intentID,
                providerID: selection.providerID
            )
        }
        stored.selectionCount -= 1
        guard stored.lifecycle == .active || stored.lifecycle == .draining,
              stored.isHealthy,
              let binding = stored.candidate.bindings[selection.intentID],
              let mailbox = stored.candidate.mailbox(
                  for: selection.intentID
              ),
              binding.isExported
        else {
            generations[key] = stored
            retireDrainedGenerationIfIdle(key)
            tryStartShutdown(key)
            throw ProviderResolutionError.providerUnavailable(
                intentID: selection.intentID,
                providerID: selection.providerID
            )
        }

        stored.leaseCount += 1
        generations[key] = stored
        let token = ProviderLeaseToken { [registry = self] in
            await registry.release(key)
        }
        return ProviderLease(
            providerID: selection.providerID,
            owner: stored.candidate.owner,
            principal: stored.candidate.principal,
            generation: key.generation,
            policyFingerprint: stored.candidate.policyFingerprint,
            binding: binding,
            mailbox: mailbox,
            token: token
        )
    }

    public func releaseSelection(_ selection: ProviderSelection) {
        let key = GenerationKey(
            providerID: selection.providerID,
            generation: selection.generation,
            identity: selection.identity
        )
        guard selectionReservations.removeValue(forKey: selection.reservationID) == key,
              var stored = generations[key],
              stored.selectionCount > 0
        else {
            return
        }
        stored.selectionCount -= 1
        generations[key] = stored
        retireDrainedGenerationIfIdle(key)
        tryStartShutdown(key)
    }

    public func resolveAndAcquire(
        _ request: ProviderResolutionRequest
    ) throws -> ProviderLease {
        try acquire(resolveAndHold(request))
    }

    public func disable(_ providerID: ProviderID) throws {
        guard owners[providerID] != nil else {
            throw ProviderRegistryError.providerNotFound(providerID)
        }
        removeActiveRoutes(for: providerID)

        let cancellableKeys: [GenerationKey] = generations.compactMap { key, stored in
            guard key.providerID == providerID,
                  [
                      ProviderLifecycle.active,
                      .draining,
                      .staging,
                  ].contains(stored.lifecycle)
            else {
                return nil
            }
            return key
        }
        for key in cancellableKeys {
            guard var stored = generations[key] else { continue }
            stored.lifecycle = .disabled
            stored.drainTask?.cancel()
            stored.drainTask = nil
            generations[key] = stored
            requestRetirement(key, reason: .disabled)
        }
        configuredDefaults = configuredDefaults.filter { $0.value != providerID }
        advanceRevision()
    }

    public func uninstall(_ providerID: ProviderID) throws {
        guard owners[providerID] != nil else {
            throw ProviderRegistryError.providerNotFound(providerID)
        }
        removeActiveRoutes(for: providerID)

        let keys = generations.keys.filter { $0.providerID == providerID }
        for key in keys {
            guard var stored = generations[key] else { continue }
            stored.lifecycle = .retired
            stored.drainTask?.cancel()
            stored.drainTask = nil
            generations[key] = stored
            requestRetirement(key, reason: .uninstalled)
        }
        owners[providerID] = nil
        configuredDefaults = configuredDefaults.filter { $0.value != providerID }
        advanceRevision()
    }

    public func snapshot() -> ProviderRegistrySnapshot {
        let liveSnapshots = generations.values.map(makeSnapshot)
        let snapshots = (retiredHistory + liveSnapshots).sorted {
            ($0.providerID.rawValue, $0.generation)
                < ($1.providerID.rawValue, $1.generation)
        }

        return ProviderRegistrySnapshot(
            revision: revision,
            generations: snapshots,
            configuredDefaults: configuredDefaults,
            residentGenerations: generations.count,
            retiredHistoryEntries: retiredHistory.count
        )
    }

    private func release(_ key: GenerationKey) {
        guard var stored = generations[key], stored.leaseCount > 0 else { return }
        stored.leaseCount -= 1
        generations[key] = stored
        retireDrainedGenerationIfIdle(key)
        tryStartShutdown(key)
    }

    private func beginDraining(_ key: GenerationKey) {
        guard var stored = generations[key], stored.lifecycle == .active else { return }
        if stored.leaseCount == 0, stored.selectionCount == 0 {
            stored.lifecycle = .retired
            generations[key] = stored
            requestRetirement(key, reason: .drained)
            return
        }

        stored.lifecycle = .draining
        let timeout = stored.candidate.drainTimeout
        let task = Task { [registry = self] in
            do {
                try await ContinuousClock().sleep(for: timeout)
            } catch {
                return
            }
            await registry.forceRetire(key)
        }
        stored.drainTask = task
        generations[key] = stored
    }

    private func retireDrainedGenerationIfIdle(_ key: GenerationKey) {
        guard var stored = generations[key],
              stored.lifecycle == .draining,
              stored.leaseCount == 0,
              stored.selectionCount == 0
        else {
            return
        }
        stored.lifecycle = .retired
        stored.drainTask?.cancel()
        stored.drainTask = nil
        generations[key] = stored
        advanceRevision()
        requestRetirement(key, reason: .drained)
    }

    private func forceRetire(_ key: GenerationKey) {
        guard var stored = generations[key], stored.lifecycle == .draining else { return }
        stored.lifecycle = .retired
        stored.drainTask = nil
        generations[key] = stored
        advanceRevision()
        requestRetirement(key, reason: .drainDeadlineExceeded)
    }

    private func removeActiveRoutes(for providerID: ProviderID) {
        for intentID in Array(activeRoutes.keys) {
            activeRoutes[intentID]?[providerID] = nil
            if activeRoutes[intentID]?.isEmpty == true {
                activeRoutes[intentID] = nil
            }
        }
    }

    private func requestRetirement(
        _ key: GenerationKey,
        reason: ProviderRetirementReason
    ) {
        guard let stored = generations[key] else { return }
        if retirementReasons[key] == nil {
            retirementReasons[key] = reason
        }
        guard mailboxWaitKeys.insert(key).inserted else {
            tryStartShutdown(key)
            return
        }

        let mailboxes = stored.candidate.executionLanes.map(\.mailbox)
        Task { [registry = self] in
            await withTaskGroup(of: Void.self) { group in
                for mailbox in mailboxes {
                    group.addTask {
                        await mailbox.retireAndWaitUntilIdle()
                    }
                }
                await group.waitForAll()
            }
            await registry.mailboxDidBecomeIdle(key)
        }
    }

    private func mailboxDidBecomeIdle(_ key: GenerationKey) {
        guard generations[key] != nil else { return }
        mailboxIdleKeys.insert(key)
        tryStartShutdown(key)
    }

    private func tryStartShutdown(_ key: GenerationKey) {
        guard let stored = generations[key],
              stored.leaseCount == 0,
              stored.selectionCount == 0,
              mailboxIdleKeys.contains(key),
              let reason = retirementReasons[key],
              shutdownKeys.insert(key).inserted
        else {
            return
        }

        let candidate = stored.candidate
        Task { [registry = self] in
            await candidate.shutdown(reason: reason)
            await registry.finishShutdown(key)
        }
    }

    private func finishShutdown(_ key: GenerationKey) {
        guard shutdownKeys.contains(key),
              let stored = generations.removeValue(forKey: key)
        else {
            return
        }

        let lookupKey = GenerationLookupKey(
            providerID: key.providerID,
            generation: key.generation
        )
        if generationKeys[lookupKey] == key {
            generationKeys[lookupKey] = nil
        }
        retirementReasons[key] = nil
        mailboxWaitKeys.remove(key)
        mailboxIdleKeys.remove(key)
        shutdownKeys.remove(key)

        retiredHistory.append(makeSnapshot(stored))
        if retiredHistory.count > retiredHistoryLimit {
            retiredHistory.removeFirst(retiredHistory.count - retiredHistoryLimit)
        }
        advanceRevision()
    }

    private func generationKey(
        providerID: ProviderID,
        generation: UInt64
    ) -> GenerationKey? {
        generationKeys[
            GenerationLookupKey(providerID: providerID, generation: generation)
        ]
    }

    private func makeSnapshot(_ stored: StoredGeneration) -> ProviderGenerationSnapshot {
        ProviderGenerationSnapshot(
            providerID: stored.candidate.providerID,
            owner: stored.candidate.owner,
            principal: stored.candidate.principal,
            generation: stored.candidate.generation,
            lifecycle: stored.lifecycle,
            intentIDs: stored.candidate.bindings.keys.sorted {
                $0.rawValue < $1.rawValue
            },
            exportedIntentIDs: stored.candidate.bindings.values
                .filter(\.isExported)
                .map(\.intentID)
                .sorted { $0.rawValue < $1.rawValue },
            policyFingerprint: stored.candidate.policyFingerprint,
            selectionCount: stored.selectionCount,
            leaseCount: stored.leaseCount,
            isHealthy: stored.isHealthy,
            failure: stored.failure
        )
    }

    private func advanceRevision() {
        revision = revision.incremented()
    }
}
