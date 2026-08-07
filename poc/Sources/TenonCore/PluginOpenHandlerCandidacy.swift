import Foundation
import TenonIntentCore

/// What a plugin's declaration of a delegable (`open`-class) contract means before the
/// person has said anything about it.
///
/// Declaring is free and inert: the plugin loads, everything else it provides works, and it
/// simply is not the handler yet. Being *chosen* is the person's decision. Without this
/// split, declaring "I can open addresses" is fatal — `ProviderActivationCoordinator`
/// refuses a plugin binding to an unapproved open contract, and the host marks the whole
/// plugin failed — so the shipped browser would go dark the moment it offered to help.
///
/// Candidacy is product state, not kernel state: it is about what a person has agreed to.
/// The kernel keeps its strict rule and the host simply does not offer the binding until
/// the approval exists. Approval then re-stages the plugin through the reload path that
/// already exists.
///
/// See `docs/design-open-handlers.md`.
public struct PluginOpenHandlerCandidacy: Equatable, Sendable {
    /// Contracts that bind now: everything the plugin owns outright, plus the delegable
    /// ones this person has approved it for.
    public let binds: [IntentID]

    /// Delegable contracts the plugin has declared and nobody has approved. These are
    /// offers, not failures — the plugin appears in the chooser once approved.
    public let awaitingApproval: [IntentID]

    /// Splits what a plugin declared into what routes now and what is waiting on a person.
    ///
    /// - Parameters:
    ///   - declared: the intents the manifest provides.
    ///   - delegable: the `open`-class contracts in the catalog. A contract outside this
    ///     set is the plugin's own and needs nobody's permission.
    ///   - approved: the delegable contracts this person approved *for this plugin*.
    public static func partition(
        declared: [IntentID],
        delegable: Set<IntentID>,
        approved: Set<IntentID>
    ) -> Self {
        var binds: [IntentID] = []
        var awaiting: [IntentID] = []
        for intentID in declared.sorted(by: { $0.rawValue < $1.rawValue }) {
            if delegable.contains(intentID), !approved.contains(intentID) {
                awaiting.append(intentID)
            } else {
                binds.append(intentID)
            }
        }
        return Self(binds: binds, awaitingApproval: awaiting)
    }

    /// An approval for a contract the plugin never declared means nothing and must not
    /// widen anything. The coordinator already refuses that combination outright
    /// (`approvedOpenIntentNotDeclared`); this keeps the host from constructing it.
    public static func effectiveApprovals(
        declared: [IntentID],
        approved: Set<IntentID>
    ) -> Set<IntentID> {
        approved.intersection(declared)
    }
}
