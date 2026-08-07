// @domain: pane-chrome
/// Every header control a BUILT-IN pane may put in the chrome, and the only tokens the
/// built-in router accepts.
///
/// Closed by construction: a projection mints a header item's id only from a case's
/// `rawValue`, and the router resolves an id only back into a case, so no free-form string
/// ever routes between two parts of the one host semantic owner.
/// `docs/architecture-interaction-boundaries.md` requires a DIRECT call to use typed Swift
/// domain or application-service interfaces; this enum is what keeps the built-in half typed
/// while a plugin's item id stays an opaque string, relayed verbatim to that plugin's own
/// `onSelect` (invariants 6 and 9).
///
/// Each case's payload is minted from the owning view's own `RawRepresentable` enum
/// (`DiffStyle: String`, `ChangesLayout: String`, `AgentLensPresentation: String`), so the two
/// ends of the contract cannot drift apart.
///
/// A case exists for each control a built-in pane actually puts in the chrome. A pane whose
/// header is pure status — a badge, a dot, a spinner — publishes no interactive item and
/// therefore needs no case here.
enum PaneHeaderCommand: String, CaseIterable, Sendable {
    /// Value: a `DiffStyle` raw value — "unified" or "split".
    case diffStyle = "diff.style"
    /// Value: a `ChangesLayout` raw value — "tree" or "flat".
    case changesLayout = "changes.layout"
    /// No value. The pane re-reads the working tree.
    case changesRefresh = "changes.refresh"
    /// Value: an `AgentLensPresentation` raw value — "session", "terminal" or "split".
    ///
    /// One control, three states, two properties: the pane holds *which renderer* and
    /// *whether both are shown* separately, and the picker is the one place a person names a
    /// combination of them. The mapping between the two shapes lives on
    /// `AgentLensPresentation`, so the value the router relays and the state the pane keeps
    /// are read off one enum.
    case agentLensPresentation = "agentLens.presentation"
    /// No value. The pane shows or hides its context-and-evidence panel; the toggle's `isOn`
    /// reports which of those it currently is.
    case agentLensInspector = "agentLens.inspector"
}
