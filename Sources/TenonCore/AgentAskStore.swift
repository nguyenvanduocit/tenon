// @domain: agent-control
import Foundation
import TenonIntentCore

// MARK: - Question model  @domain: agent-control

/// The identity Tenon routes one declared question to.
///
/// A human and an agent use the same record and answer path. The enum carries no work
/// placement or scheduling semantics; an agent recipient is only an exact principal.
public enum AgentQuestionRecipient: Sendable, Equatable, Hashable {
    case human
    case agent(IntentPrincipal)
}

public struct AgentQuestionChoice: Sendable, Equatable {
    public let id: String
    public let label: String
    public let value: IntentValue

    public init(id: String, label: String, value: IntentValue) {
        self.id = id
        self.label = label
        self.value = value
    }
}

public struct AgentQuestionEvidence: Sendable, Equatable {
    public let label: String
    public let url: String

    public init(label: String, url: String) {
        self.label = label
        self.url = url
    }
}

public struct AgentAskRequest: Sendable, Equatable {
    public let paneID: UUID
    public let asker: IntentPrincipal
    public let recipient: AgentQuestionRecipient
    public let question: String
    public let choices: [AgentQuestionChoice]
    public let evidence: [AgentQuestionEvidence]
    public let timeoutMilliseconds: Int

    public init(
        paneID: UUID,
        asker: IntentPrincipal,
        recipient: AgentQuestionRecipient,
        question: String,
        choices: [AgentQuestionChoice],
        evidence: [AgentQuestionEvidence],
        timeoutMilliseconds: Int
    ) {
        self.paneID = paneID
        self.asker = asker
        self.recipient = recipient
        self.question = question
        self.choices = choices
        self.evidence = evidence
        self.timeoutMilliseconds = timeoutMilliseconds
    }
}

public enum AgentQuestionState: Sendable, Equatable {
    case pending
    case answered(
        choiceID: String,
        value: IntentValue,
        responder: IntentPrincipal
    )
    case expired
    case paneClosed
}

public struct AgentQuestionRecord: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let paneID: UUID
    public let asker: IntentPrincipal
    public let recipient: AgentQuestionRecipient
    public let question: String
    public let choices: [AgentQuestionChoice]
    public let evidence: [AgentQuestionEvidence]
    public let createdAt: Date
    public let expiresAt: Date
    public var state: AgentQuestionState
}

public enum AgentAskResultStatus: String, Sendable, Equatable {
    case answered
    case expired
}

public struct AgentAskResult: Sendable, Equatable {
    public let questionID: UUID
    public let status: AgentAskResultStatus
    public let value: IntentValue?
}

public enum AgentQuestionFilter: Sendable, Equatable {
    case pane(UUID)
    case recipient(AgentQuestionRecipient)
}

public enum AgentAskStoreError: Error, Sendable, Equatable {
    case askerMustBeProgrammatic
    case invalidRecipient
    case invalidQuestion
    case invalidChoices
    case invalidEvidence
    case invalidTimeout
    case questionAlreadyPending
    case capacityExceeded
    case questionNotFound
    case questionNotPending
    case choiceNotOffered
    case responderDoesNotMatchRecipient
    case paneClosed
}

// MARK: - Pane-owned store  @domain: agent-control

/// Pane-owned state for declared agent questions.
///
/// The caller owns only its suspended waiter. Cancelling that waiter removes it, while the
/// question remains in this actor until it is answered, expires, or its pane closes. That
/// separation is what makes provider death and context compaction non-destructive.
public actor AgentAskStore {
    public static let maximumQuestionCharacters = 8 * 1024
    public static let maximumChoiceCount = 16
    public static let maximumEvidenceCount = 16
    public static let maximumTimeoutMilliseconds = 55000
    public static let maximumRecords = 64

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<AgentAskResult, any Error>
    }

    private struct Subscriber {
        let filter: AgentQuestionFilter
        let continuation: AsyncStream<AgentQuestionRecord>.Continuation
    }

    private var records: [UUID: AgentQuestionRecord] = [:]
    private var recordOrder: [UUID] = []
    private var pendingByPane: [UUID: UUID] = [:]
    private var waiters: [UUID: Waiter] = [:]
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]
    private var subscribers: [UUID: Subscriber] = [:]

    public init() {}

    public func ask(_ request: AgentAskRequest) async throws -> AgentAskResult {
        try Task.checkCancellation()
        try Self.validate(request)
        guard pendingByPane[request.paneID] == nil else {
            throw AgentAskStoreError.questionAlreadyPending
        }
        pruneSettledRecordsIfNeeded()
        guard records.count < Self.maximumRecords else {
            throw AgentAskStoreError.capacityExceeded
        }

        let questionID = UUID()
        let waiterID = UUID()
        let now = Date()
        let record = AgentQuestionRecord(
            id: questionID,
            paneID: request.paneID,
            asker: request.asker,
            recipient: request.recipient,
            question: request.question,
            choices: request.choices,
            evidence: request.evidence,
            createdAt: now,
            expiresAt: now.addingTimeInterval(
                Double(request.timeoutMilliseconds) / 1000
            ),
            state: .pending
        )
        records[questionID] = record
        recordOrder.append(questionID)
        pendingByPane[request.paneID] = questionID

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[questionID] = Waiter(
                    id: waiterID,
                    continuation: continuation
                )
                publish(record)
                startExpiry(for: record)
                // Cancellation may win between entering the handler and attaching this
                // continuation. Re-check after attachment so that ordering cannot strand a
                // waiter; the pane-owned record deliberately remains.
                if Task.isCancelled {
                    cancelWaiter(
                        questionID: questionID,
                        waiterID: waiterID
                    )
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(
                    questionID: questionID,
                    waiterID: waiterID
                )
            }
        }
    }

    public func answer(
        questionID: UUID,
        responder: IntentPrincipal,
        choiceID: String
    ) throws {
        guard var record = records[questionID] else {
            throw AgentAskStoreError.questionNotFound
        }
        guard record.state == .pending else {
            throw AgentAskStoreError.questionNotPending
        }
        guard Self.matches(responder, recipient: record.recipient) else {
            throw AgentAskStoreError.responderDoesNotMatchRecipient
        }
        guard let choice = record.choices.first(where: { $0.id == choiceID }) else {
            throw AgentAskStoreError.choiceNotOffered
        }

        record.state = .answered(
            choiceID: choice.id,
            value: choice.value,
            responder: responder
        )
        settle(record)
        waiters.removeValue(forKey: questionID)?.continuation.resume(
            returning: AgentAskResult(
                questionID: questionID,
                status: .answered,
                value: choice.value
            )
        )
    }

    public func question(id: UUID) -> AgentQuestionRecord? {
        records[id]
    }

    public func pendingQuestions(
        for recipient: AgentQuestionRecipient
    ) -> [AgentQuestionRecord] {
        recordOrder.compactMap { id in
            guard let record = records[id],
                  record.state == .pending,
                  record.recipient == recipient
            else { return nil }
            return record
        }
    }

    public func updates(
        matching filter: AgentQuestionFilter
    ) -> AsyncStream<AgentQuestionRecord> {
        let subscriberID = UUID()
        let pair = AsyncStream<AgentQuestionRecord>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.maximumRecords)
        )
        subscribers[subscriberID] = Subscriber(
            filter: filter,
            continuation: pair.continuation
        )
        pair.continuation.onTermination = { @Sendable _ in
            Task { await self.removeSubscriber(subscriberID) }
        }
        for id in recordOrder {
            if let record = records[id],
               record.state == .pending,
               Self.matches(record, filter: filter)
            {
                pair.continuation.yield(record)
            }
        }
        return pair.stream
    }

    public func expireDue(at date: Date = Date()) {
        let due = recordOrder.compactMap { id -> UUID? in
            guard let record = records[id],
                  record.state == .pending,
                  record.expiresAt <= date
            else { return nil }
            return id
        }
        for id in due {
            guard var record = records[id] else { continue }
            record.state = .expired
            settle(record)
            waiters.removeValue(forKey: id)?.continuation.resume(
                returning: AgentAskResult(
                    questionID: id,
                    status: .expired,
                    value: nil
                )
            )
        }
    }

    public func closePane(_ paneID: UUID) {
        guard let id = pendingByPane[paneID], var record = records[id] else {
            return
        }
        record.state = .paneClosed
        settle(record)
        waiters.removeValue(forKey: id)?.continuation.resume(
            throwing: AgentAskStoreError.paneClosed
        )
    }
}

// MARK: - Validation and lifecycle  @domain: agent-control

private extension AgentAskStore {
    static func validate(_ request: AgentAskRequest) throws {
        guard [.plugin, .cli, .agent].contains(request.asker.kind) else {
            throw AgentAskStoreError.askerMustBeProgrammatic
        }
        if case let .agent(principal) = request.recipient,
           principal.kind != .agent
        {
            throw AgentAskStoreError.invalidRecipient
        }
        guard !request.question.isEmpty,
              request.question.count <= maximumQuestionCharacters
        else {
            throw AgentAskStoreError.invalidQuestion
        }
        guard !request.choices.isEmpty,
              request.choices.count <= maximumChoiceCount,
              Set(request.choices.map(\.id)).count == request.choices.count,
              request.choices.allSatisfy({ choice in
                  !choice.id.isEmpty && choice.id.utf8.count <= 128
                      && !choice.label.isEmpty && choice.label.count <= 256
                      && isScalar(choice.value)
              })
        else {
            throw AgentAskStoreError.invalidChoices
        }
        guard !request.evidence.isEmpty,
              request.evidence.count <= maximumEvidenceCount,
              request.evidence.allSatisfy({ evidence in
                  !evidence.label.isEmpty && evidence.label.count <= 256
                      && evidence.url.utf8.count <= 16384
                      && URL(string: evidence.url)?.scheme != nil
              })
        else {
            throw AgentAskStoreError.invalidEvidence
        }
        guard (1 ... maximumTimeoutMilliseconds).contains(
            request.timeoutMilliseconds
        ) else {
            throw AgentAskStoreError.invalidTimeout
        }
    }

    static func isScalar(_ value: IntentValue) -> Bool {
        switch value {
        case .bool, .integer, .number, .string:
            true
        case .null, .array, .object:
            false
        }
    }

    static func matches(
        _ responder: IntentPrincipal,
        recipient: AgentQuestionRecipient
    ) -> Bool {
        switch recipient {
        case .human:
            responder.kind == .user
        case let .agent(principal):
            responder == principal
        }
    }

    static func matches(
        _ record: AgentQuestionRecord,
        filter: AgentQuestionFilter
    ) -> Bool {
        switch filter {
        case let .pane(paneID):
            record.paneID == paneID
        case let .recipient(recipient):
            record.recipient == recipient
        }
    }

    func startExpiry(for record: AgentQuestionRecord) {
        let delay = max(0, record.expiresAt.timeIntervalSinceNow)
        expiryTasks[record.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.expireDue(at: record.expiresAt)
        }
    }

    func settle(_ record: AgentQuestionRecord) {
        records[record.id] = record
        pendingByPane[record.paneID] = nil
        expiryTasks.removeValue(forKey: record.id)?.cancel()
        publish(record)
    }

    func publish(_ record: AgentQuestionRecord) {
        for subscriber in subscribers.values
            where Self.matches(record, filter: subscriber.filter)
        {
            subscriber.continuation.yield(record)
        }
    }

    func cancelWaiter(questionID: UUID, waiterID: UUID) {
        guard waiters[questionID]?.id == waiterID else { return }
        waiters.removeValue(forKey: questionID)?.continuation.resume(
            throwing: CancellationError()
        )
    }

    func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    func pruneSettledRecordsIfNeeded() {
        guard records.count >= Self.maximumRecords else { return }
        while records.count >= Self.maximumRecords,
              let index = recordOrder.firstIndex(where: { id in
                  records[id]?.state != .pending
              })
        {
            let id = recordOrder.remove(at: index)
            records[id] = nil
        }
    }
}
