// @domain: intent-bus
import Foundation
import TenonIntentCore

/// Host-wide bounds shared by every v1 core intent.
///
/// Inline text is deliberately below the envelope limit so its object metadata
/// still fits. V1 contracts fail explicitly when content cannot fit inline;
/// resource transport will be introduced only with a real resource lifecycle.
public enum CoreIntentPayloadPolicy {
    public static let maximumEncodedBytes = IntentValueLimits.default.maxEncodedBytes
    public static let hardMaximumEncodedBytes =
        IntentValueLimits.hardMaximumEncodedBytes
    public static let maximumInlineTextCharacters = 48 * 1024

    /// Rows a single `terminal.scrollback.read.v1` page may carry. A page also has to fit
    /// `maximumInlineTextCharacters`, so this is the row-count half of a two-sided bound:
    /// whichever runs out first ends the page, and the cursor carries the rest.
    public static let maximumScrollbackPageLines = 2_000

    /// The cursor is `"<nextRow>:<totalRows>"` — two decimal integers and a colon. The
    /// bound exists so a caller cannot hand back an unbounded string and make the host
    /// parse it.
    public static let maximumScrollbackCursorCharacters = 64

    /// The cursor is `"v1:<offset>:<size>-<mtime-sec>-<mtime-nsec>"` — a decimal byte
    /// offset plus the hex file identity it was issued against. The bound exists so a
    /// caller cannot hand back an unbounded string and make the host parse it.
    public static let maximumFileReadCursorCharacters = 96

    /// The cursor is `"v1:<stagedByteCount>:<staging token>"` — a decimal byte count
    /// plus the random identity of the staging it continues. The bound exists so a
    /// caller cannot hand back an unbounded string and make the host parse it.
    public static let maximumFileWriteCursorCharacters = 96

    /// Total bytes one staged `filesystem.file.write.v1` sequence may accumulate
    /// before it commits. Each page is separately bounded by
    /// `maximumInlineTextCharacters`; this is the whole-file half of that two-sided
    /// bound, sized for supervision artifacts like the kanban board rather than for
    /// bulk transfer.
    public static let maximumStagedFileWriteBytes = 1_024 * 1_024
}

/// One row in the canonical table. The declaration describes the public contract; the rule
/// describes host-owned routing, authority, exposure, admission, and resource bounds.
public struct CoreIntentDefinition: Sendable, Equatable {
    public let declaration: IntentContractDeclaration
    public let dispatchRule: IntentDispatchRule

    public init(
        declaration: IntentContractDeclaration,
        dispatchRule: IntentDispatchRule
    ) {
        self.declaration = declaration
        self.dispatchRule = dispatchRule
    }
}

/// The immutable result of compiling the core table.
public struct CompiledCoreIntentCatalog: Sendable, Equatable {
    public let trustedProviderID: ProviderID
    public let definitions: [CoreIntentDefinition]
    public let contractSnapshot: ContractCatalogSnapshot
    public let dispatcherRuleRevision: UInt64
    public let dispatchRules: [IntentID: IntentDispatchRule]

    public init(
        trustedProviderID: ProviderID,
        definitions: [CoreIntentDefinition],
        contractSnapshot: ContractCatalogSnapshot,
        dispatcherRuleRevision: UInt64,
        dispatchRules: [IntentID: IntentDispatchRule]
    ) {
        self.trustedProviderID = trustedProviderID
        self.definitions = definitions
        self.contractSnapshot = contractSnapshot
        self.dispatcherRuleRevision = dispatcherRuleRevision
        self.dispatchRules = dispatchRules
    }

    public func rule(for intentID: IntentID) -> IntentDispatchRule? {
        dispatchRules[intentID]
    }
}

public enum CoreIntentCatalogError: Error, Sendable, Equatable {
    case inventoryMismatch(expected: Int, actual: Int)
    case duplicateIntentID(String)
    case ruleIntentMismatch(declaration: String, rule: String)
    case trustedProviderMismatch(intent: String)
    case exposureOutsideAudience(intent: String, audience: IntentAudience)
    case invalidPayloadLimit(intent: String, maximumEncodedBytes: Int)
    case authoritativeContractMissing(String)
    case authoritativeRuleMismatch(String)
}

/// Installs and caches the canonical table once in one authoritative kernel.
///
/// The in-flight task is installed before the first suspension, so concurrent callers share
/// the same schema compilation and rule registration rather than racing independent installs.
public actor CoreIntentCatalog {
    public static let trustedProviderIDRawValue = "dev.tenon.core"

    private let catalog: ContractCatalog
    private let dispatcher: IntentDispatcher
    private var compiled: CompiledCoreIntentCatalog?
    private var compilationTask: Task<CompiledCoreIntentCatalog, any Error>?
    internal private(set) var compilationCount = 0

    /// Binds this loader to the kernel composition root whose catalog and dispatcher are
    /// authoritative for production. Keeping both references from one component value avoids
    /// accidentally registering rules against a dispatcher backed by a different catalog.
    public init(components: IntentKernelComponents) {
        catalog = components.catalog
        dispatcher = components.dispatcher
    }

    public static func trustedProviderID() throws -> ProviderID {
        try ProviderID(trustedProviderIDRawValue)
    }

    /// Returns the declarative table without compiling validators.
    public static func definitions() throws -> [CoreIntentDefinition] {
        try makeDefinitions(trustedProviderID: trustedProviderID())
    }

    public func install() async throws -> CompiledCoreIntentCatalog {
        if let compiled {
            return compiled
        }
        if let compilationTask {
            return try await compilationTask.value
        }

        compilationCount += 1
        let catalog = catalog
        let dispatcher = dispatcher
        let task = Task {
            try await Self.installCatalog(
                into: catalog,
                dispatcher: dispatcher
            )
        }
        compilationTask = task

        do {
            let value = try await task.value
            compiled = value
            compilationTask = nil
            return value
        } catch {
            compilationTask = nil
            throw error
        }
    }
}
