// @domain: pane-chrome, plugin-contributions
import Foundation

/// One control in a pane's chrome header.
///
/// Flat and non-recursive on purpose. A 34-point strip has no meaning for `scroll`, `grid`,
/// `card`, `webview`, or a nested stack, so the header vocabulary makes those states
/// *unrepresentable* rather than filtering them at parse time — a plugin author never has to
/// learn which two thirds of the body vocabulary are silently dropped up here.
///
/// It is a VALUE, not a mechanism. Built-in panes fill it with typed Swift (DIRECT); plugins
/// fill it by publishing a `header` key inside the `views.set` CONTRIBUTION. One value, two
/// owners, one renderer — that is invariant 6 satisfied, not bypassed.
///
/// Every bound below is enforced by `bounded()`, which `PaneHeader.init` runs over every item
/// it accepts, so a built-in Swift producer is clamped by exactly the same rule a plugin is
/// (invariant 10). A Swift `enum` case cannot carry a custom initialiser, so `PaneHeader.init`
/// is where "the initialiser" lives for this vocabulary; there is no second, looser door.
///
/// Bounds come in two flavours, and which one applies is a judgement about *identity*:
///
/// - **Display text truncates.** A label, a badge, a tooltip and a field's value are things a
///   human reads; a shortened one still says roughly what it said.
/// - **Identity drops its item.** An `id`, a `systemName` and a `selection` are things the host
///   routes and resolves on. A truncated identifier would silently name a different control, or
///   merge two of them, and report a value its owner never published — so an identifier that
///   does not fit is refused outright rather than mangled. `reservedIDs` is the same rule
///   pointed at the host's own names.
///
/// The `accessibilityID` every interactive case carries is host-only and carries no bound. A
/// plugin decoder never populates it — an accessibility identifier is XCUITest identity, not
/// contributor data, and a contributor able to mint one could rename the host's own test
/// anchors out from under the UI suite. Built-in producers set it so anchors like
/// `tenon.agentLens.mode` survive the move into chrome, and the renderer reads it off the case
/// it is already destructuring.
public enum PaneHeaderItem: Sendable, Hashable {
    /// 7-point state dot — the same vocabulary the tab chip and sidebar use.
    case dot(id: String, tint: ColorToken, tooltip: String?)
    /// Static text at header scale. Truncates; never folds away whole.
    case label(
        id: String,
        text: String,
        weight: FontWeight,
        color: ColorToken,
        truncation: PaneHeaderTruncation,
        tooltip: String?
    )
    /// Capsule count/status chip.
    case badge(id: String, text: String, tint: ColorToken, tooltip: String?)
    /// Static SF Symbol. `systemName` matches `PluginViewNode.image`'s field name.
    case image(id: String, systemName: String, tint: ColorToken, tooltip: String?)
    /// Indeterminate progress.
    case spinner(id: String)
    /// Tappable SF Symbol. Reports `PaneHeaderAction(itemID: id, value: nil)`.
    case iconButton(
        id: String,
        systemName: String,
        tint: ColorToken,
        isEnabled: Bool,
        tooltip: String?,
        accessibilityID: String?
    )
    /// Two-state SF Symbol; tinted amber when on. Reports the id with no value; the owner
    /// flips its own state. (`isOn` is the item's own current state, not the next one.)
    case toggle(
        id: String,
        systemName: String,
        isOn: Bool,
        isEnabled: Bool,
        tooltip: String?,
        accessibilityID: String?
    )
    /// Segmented selector. Reports the chosen segment's `value`.
    case segmented(
        id: String,
        segments: [PaneHeaderSegment],
        selection: String,
        isEnabled: Bool,
        accessibilityID: String?
    )
    /// Pull-down menu of VALUES (never a contributor-authored view tree — that would be a
    /// second body by another route). Reports the picked entry's `value`.
    case menu(
        id: String,
        systemName: String,
        entries: [PaneHeaderMenuEntry],
        isEnabled: Bool,
        tooltip: String?,
        accessibilityID: String?
    )
    /// The one editable control, and the one item that may absorb slack width.
    /// Commits through SUBMIT, not select. Named `textfield` to match
    /// `PluginViewNode.textfield`; `field` is taken by the body vocabulary's labelled form
    /// container and must not be reused here.
    case textfield(
        id: String,
        value: String,
        placeholder: String,
        flex: Bool,
        isEnabled: Bool,
        accessibilityID: String?
    )

    public static let maximumLabelLength = 200
    /// A chip, not a sentence: a count, a short state word, `"Changed on disk"`. It CUTS at
    /// this number instead of ellipsising, so a producer with prose to say wants a `label` —
    /// 200 characters, a `truncation` token of its own, and a visible ellipsis at whatever
    /// width the solver grants it. A badge that has to be truncated to be read was the wrong
    /// kind of item, not a badge that needs a bigger cap.
    public static let maximumBadgeLength = 24
    /// The one bound here that buys no layout. A tooltip is an `NSView` help string — AppKit
    /// wraps it, shows it transiently, and no control in the strip gets narrower because it is
    /// long. The cap exists so a published header stays a bounded value (invariant 10), not so
    /// the text fits anywhere.
    ///
    /// It is sized, therefore, by the longest thing a pane has to be able to SAY rather than by
    /// anything it has to fit. The worst case the shipped product produces is a filesystem
    /// failure that names the file it failed on, so the number is `PATH_MAX` (1024 on Darwin):
    /// a message can always at least carry the longest name macOS can give the thing it is
    /// about. Still a bound — a producer holding a genuinely unbounded string has to summarise
    /// it rather than assume this will hold.
    public static let maximumTooltipLength = 1024
    public static let maximumTextFieldLength = 2048
    /// The ceiling on every identifier-shaped field: `id`, `systemName`, and a segmented
    /// control's `selection`. Deliberately the same number as `PaneHeaderSegment` and
    /// `PaneHeaderMenuEntry` use for their `value`, because it is the same rule — one bound
    /// for identity across the whole vocabulary, and exceeding it drops the item rather than
    /// truncating a name the host is about to route on.
    public static let maximumIdentifierLength = 64

    /// The id of the one control the host composes for itself: the `…` the layout solver adds
    /// after both runs are settled.
    ///
    /// It lives on the value type rather than on the solver because the rule it anchors is a
    /// rule about *identity*, and identity is what this type owns.
    public static let overflowItemID = "tenon.paneHeader.overflow"

    /// Every id the host keeps for itself. `bounded()` refuses them, so no header — typed
    /// Swift or plugin JSON — can carry an item under one of these names.
    ///
    /// The refusal is structural, not advisory. An item wearing the host's own id would have
    /// its clicks resolved as picks in the host-composed overflow menu and dropped, and it
    /// would put two rows under one key in the single `ForEach` that draws a run, which is a
    /// duplicate-identity fault rather than a cosmetic clash.
    public static let reservedIDs: Set<String> = [overflowItemID]

    /// The item's own identity inside its view. Routing, overflow attribution and `ForEach`
    /// all key on it, which is why an empty or over-long one costs the item its place.
    public var id: String {
        switch self {
        case let .dot(id, _, _): return id
        case let .label(id, _, _, _, _, _): return id
        case let .badge(id, _, _, _): return id
        case let .image(id, _, _, _): return id
        case let .spinner(id): return id
        case let .iconButton(id, _, _, _, _, _): return id
        case let .toggle(id, _, _, _, _, _): return id
        case let .segmented(id, _, _, _, _): return id
        case let .menu(id, _, _, _, _, _): return id
        case let .textfield(id, _, _, _, _, _): return id
        }
    }

    /// Whether the item takes the mouse. Drives the card's hit-test exemption and its cursor
    /// rects: a dot, a label, a badge, an image and a spinner stay pane-drag surface.
    ///
    /// This is a real invariant, not a convenience. Every point in the header that is not the
    /// close control and not an interactive item's rect must still start a pane drag, so the
    /// set of items that answer `true` here is exactly the set of holes punched in the drag
    /// surface.
    public var isInteractive: Bool {
        switch self {
        case .dot, .label, .badge, .image, .spinner: return false
        case .iconButton, .toggle, .segmented, .menu, .textfield: return true
        }
    }

    /// Only a `textfield` may ask for slack; `PaneHeader` grants it to at most one item.
    public var wantsFlex: Bool {
        if case let .textfield(_, _, _, flex, _, _) = self { return flex }
        return false
    }

    /// The item as it is allowed to appear in a header, or `nil` when it cannot be made
    /// meaningful at all.
    ///
    /// Idempotent, so re-bounding an already-bounded item changes nothing. `PaneHeader.init`
    /// is the only caller that matters — going through the header is how both producers get
    /// the same clamp — but it is public so a decoder can reject an item before it counts
    /// against a slot's budget.
    ///
    /// An item is refused when its `id` is empty, over-long or reserved to the host, when a
    /// glyph-bearing item names no drawable symbol (an `iconButton` with no glyph is an
    /// invisible clickable rectangle, which is worse than a missing control), when a
    /// `segmented` is left with fewer than `PaneHeaderSegment.minimumSegments` usable options,
    /// or when a `menu` has no entries.
    public func bounded() -> PaneHeaderItem? {
        guard Self.isAdmissibleIdentifier(id), !Self.reservedIDs.contains(id) else { return nil }
        switch self {
        case let .dot(id, tint, tooltip):
            return .dot(id: id, tint: tint, tooltip: Self.boundedTooltip(tooltip))
        case let .label(id, text, weight, color, truncation, tooltip):
            return .label(
                id: id,
                text: String(text.prefix(Self.maximumLabelLength)),
                weight: weight,
                color: color,
                truncation: truncation,
                tooltip: Self.boundedTooltip(tooltip)
            )
        case let .badge(id, text, tint, tooltip):
            return .badge(
                id: id,
                text: String(text.prefix(Self.maximumBadgeLength)),
                tint: tint,
                tooltip: Self.boundedTooltip(tooltip)
            )
        case let .image(id, systemName, tint, tooltip):
            guard Self.isAdmissibleIdentifier(systemName) else { return nil }
            return .image(
                id: id,
                systemName: systemName,
                tint: tint,
                tooltip: Self.boundedTooltip(tooltip)
            )
        case .spinner:
            return self
        case let .iconButton(id, systemName, tint, isEnabled, tooltip, accessibilityID):
            guard Self.isAdmissibleIdentifier(systemName) else { return nil }
            return .iconButton(
                id: id,
                systemName: systemName,
                tint: tint,
                isEnabled: isEnabled,
                tooltip: Self.boundedTooltip(tooltip),
                accessibilityID: accessibilityID
            )
        case let .toggle(id, systemName, isOn, isEnabled, tooltip, accessibilityID):
            guard Self.isAdmissibleIdentifier(systemName) else { return nil }
            return .toggle(
                id: id,
                systemName: systemName,
                isOn: isOn,
                isEnabled: isEnabled,
                tooltip: Self.boundedTooltip(tooltip),
                accessibilityID: accessibilityID
            )
        case let .segmented(id, segments, selection, isEnabled, accessibilityID):
            // A selection longer than a segment's value can name no admissible option, so it
            // is malformed rather than merely unmatched — and storing it would leave an
            // unbounded string behind to represent "nothing is selected".
            guard selection.count <= Self.maximumIdentifierLength else { return nil }
            let kept = Array(segments.prefix(PaneHeaderSegment.maximumSegments))
            guard kept.count >= PaneHeaderSegment.minimumSegments else { return nil }
            return .segmented(
                id: id,
                segments: kept,
                selection: selection,
                isEnabled: isEnabled,
                accessibilityID: accessibilityID
            )
        case let .menu(id, systemName, entries, isEnabled, tooltip, accessibilityID):
            guard Self.isAdmissibleIdentifier(systemName) else { return nil }
            let kept = Array(entries.prefix(PaneHeaderMenuEntry.maximumEntries))
            guard !kept.isEmpty else { return nil }
            return .menu(
                id: id,
                systemName: systemName,
                entries: kept,
                isEnabled: isEnabled,
                tooltip: Self.boundedTooltip(tooltip),
                accessibilityID: accessibilityID
            )
        case let .textfield(id, value, placeholder, flex, isEnabled, accessibilityID):
            return .textfield(
                id: id,
                value: String(value.prefix(Self.maximumTextFieldLength)),
                // Placeholder is display text of the same class as a label, and is bounded
                // with it: a field's prompt is read, never routed on.
                placeholder: String(placeholder.prefix(Self.maximumLabelLength)),
                flex: flex,
                isEnabled: isEnabled,
                accessibilityID: accessibilityID
            )
        }
    }

    /// How this item reads once the width forces it into the overflow menu. `[]` means it
    /// simply disappears — decoration only: a spinner, a dot, a static image.
    ///
    /// The entries speak the *item's own* value space, not the overflow menu's, so the caller
    /// that folds an item must remember which item produced which entries; the folded control
    /// still has to report as itself when one is picked. Folding item by item, which is what
    /// the layout solver does, keeps that association for free.
    ///
    /// A `textfield` also returns `[]`, and that is a statement about menus rather than about
    /// text fields: a menu entry reports one fixed value and cannot accept typing, so a field
    /// has no honest folded form. The solver shrinks a field to its floor instead of folding
    /// it.
    public func overflowEntries() -> [PaneHeaderMenuEntry] {
        switch self {
        case .dot, .image, .spinner, .textfield:
            return []
        case let .label(id, text, _, _, _, _):
            // Status text that ran out of room is still the pane's news; it folds in as a
            // read-only line rather than being deleted.
            return PaneHeaderMenuEntry(value: id, label: text).map { [$0] } ?? []
        case let .badge(id, text, _, _):
            return PaneHeaderMenuEntry(value: id, label: text).map { [$0] } ?? []
        case let .iconButton(id, systemName, _, _, tooltip, _):
            return PaneHeaderMenuEntry(
                value: id,
                label: tooltip ?? id,
                systemName: systemName
            ).map { [$0] } ?? []
        case let .toggle(id, systemName, isOn, _, tooltip, _):
            return PaneHeaderMenuEntry(
                value: id,
                label: tooltip ?? id,
                systemName: systemName,
                isOn: isOn
            ).map { [$0] } ?? []
        case let .segmented(_, segments, selection, _, _):
            // The checkmark is how a folded picker still reads its own state.
            return segments.compactMap { segment in
                PaneHeaderMenuEntry(
                    value: segment.value,
                    label: segment.label ?? segment.accessibilityLabel ?? segment.value,
                    systemName: segment.systemName,
                    isOn: segment.value == selection
                )
            }
        case let .menu(_, _, entries, _, _, _):
            return entries
        }
    }

    private static func boundedTooltip(_ tooltip: String?) -> String? {
        tooltip.map { String($0.prefix(maximumTooltipLength)) }
    }

    private static func isAdmissibleIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= maximumIdentifierLength
    }
}

/// Which end of a `label` gives way when the header runs out of room.
///
/// A label never folds into the overflow menu — it truncates in place — so this token is the
/// only say its owner gets over *how*. A path set to `.head` keeps its meaningful tail.
public enum PaneHeaderTruncation: String, Sendable, Hashable {
    case head, middle, tail
    /// An unknown or omitted token falls back to `.tail`, the same degrade-to-default
    /// discipline every token enum in `PluginViewNode.swift` follows. A typo costs a label the
    /// end it wanted shortened, never the label itself — dropping a whole item over one
    /// misspelled adjective is the trade this vocabulary refuses to make.
    public init(token: String?) {
        self = token.flatMap(PaneHeaderTruncation.init(rawValue:)) ?? .tail
    }
}

/// One option of a `segmented`. A segment shows `systemName` when it has one and `label`
/// otherwise.
///
/// An icon-only segment is the only control in this vocabulary that draws no text of its own,
/// and two readers need some: the pointer wants hover text, VoiceOver wants a spoken name.
/// They are the same sentence, so a segment takes it from whichever side its author wrote it
/// on and fills the other in. Writing both keeps both — the fallback fills a gap, it never
/// overrules a choice — and a segment that already SHOWS its name synthesises nothing, because
/// a tooltip repeating the text under the pointer is noise rather than an affordance.
///
/// An icon-only segment given neither still keeps its place. Refusing it would starve its
/// picker below `minimumSegments` and delete the whole control, leaving its author nothing to
/// look at; degrading to `value` puts a visibly wrong `"seg-a"` in the hover text and in the
/// overflow menu, which is the mistake reporting itself. That is the trade this vocabulary
/// makes everywhere it can: refuse what cannot be DRAWN, degrade what cannot be READ.
public struct PaneHeaderSegment: Sendable, Hashable, Identifiable {
    public static let minimumSegments = 2
    public static let maximumSegments = 5
    public static let maximumLabelLength = 32
    /// Truncating an id would silently merge two options and report a value the owner never
    /// published, so an over-long id drops its option instead.
    public static let maximumValueLength = 64

    public let value: String
    public let label: String?
    public let systemName: String?
    public let accessibilityLabel: String?
    public let tooltip: String?
    public var id: String { value }

    /// Fails — rather than repairs — when the option would be a lie or a blank.
    ///
    /// `value` is the fact this option reports back to its owner, so it is never shortened to
    /// fit: an over-long or empty one costs the option its existence. A segment with neither a
    /// visible label nor a symbol has nothing to draw, and an invisible third of a picker is a
    /// worse outcome than a picker with one fewer choice.
    public init?(
        value: String,
        label: String? = nil,
        systemName: String? = nil,
        accessibilityLabel: String? = nil,
        tooltip: String? = nil
    ) {
        let visibleLabel = label.flatMap { text -> String? in
            text.isEmpty ? nil : String(text.prefix(Self.maximumLabelLength))
        }
        let symbol = systemName.flatMap { name -> String? in
            name.isEmpty || name.count > Self.maximumValueLength ? nil : name
        }
        guard !value.isEmpty,
              value.count <= Self.maximumValueLength,
              visibleLabel != nil || symbol != nil
        else { return nil }
        // Empty is absent, the way it already is for `label` and `systemName`: an empty spoken
        // name reads as silence and an empty tooltip as a blank yellow box, and neither is a
        // thing an author asks for on purpose.
        let spoken = accessibilityLabel.flatMap { text -> String? in
            text.isEmpty ? nil : String(text.prefix(Self.maximumLabelLength))
        }
        // A segment's tooltip is a tooltip like any other and takes the vocabulary's one bound
        // for the concept — the bound belongs to the kind of string, not to where it hangs.
        let hover = tooltip.flatMap { text -> String? in
            text.isEmpty ? nil : String(text.prefix(PaneHeaderItem.maximumTooltipLength))
        }
        self.value = value
        self.label = visibleLabel
        self.systemName = symbol
        if visibleLabel == nil {
            // The name lent back is bounded like a segment's visible label, because standing in
            // for one is exactly what it is doing.
            self.accessibilityLabel = spoken
                ?? hover.map { String($0.prefix(Self.maximumLabelLength)) }
            self.tooltip = hover ?? spoken
        } else {
            self.accessibilityLabel = spoken
            self.tooltip = hover
        }
    }
}

/// One line of a `menu`, and the form every folded control takes in the overflow menu.
public struct PaneHeaderMenuEntry: Sendable, Hashable, Identifiable {
    public static let maximumEntries = 12
    public static let maximumLabelLength = 64
    public static let maximumValueLength = 64

    /// `value`/`label` deliberately match `PluginRowItem`'s and `RowMenuItem`'s field names —
    /// one word per concept across the whole plugin API.
    public let value: String
    public let label: String
    public let systemName: String?
    /// A checkmark; how a folded `segmented` or `toggle` still reads its own state.
    public let isOn: Bool
    public let separatorBefore: Bool
    public var id: String { value }

    /// Fails on an entry that could not be picked or could not be read.
    ///
    /// `value` obeys the same identity rule as `PaneHeaderSegment.value` — it is reported
    /// verbatim to the owner, so it drops rather than truncates. `label` is display text and
    /// truncates, but an empty one leaves a blank clickable line, which is not an option a
    /// human can choose on purpose. An unusable `systemName` degrades to no symbol, because
    /// the label still carries the meaning.
    public init?(
        value: String,
        label: String,
        systemName: String? = nil,
        isOn: Bool = false,
        separatorBefore: Bool = false
    ) {
        guard !value.isEmpty, value.count <= Self.maximumValueLength, !label.isEmpty else {
            return nil
        }
        self.value = value
        self.label = String(label.prefix(Self.maximumLabelLength))
        self.systemName = systemName.flatMap { name -> String? in
            name.isEmpty || name.count > Self.maximumValueLength ? nil : name
        }
        self.isOn = isOn
        self.separatorBefore = separatorBefore
    }
}

/// The one fact a header control emits. `value` is a segment/menu value, or a textfield's
/// submitted text; nil for a plain button or toggle.
///
/// One struct for all ten kinds, because the click that comes back out of a header is the same
/// EVENT fact as a row click or a body button click — the header adds a place to put controls,
/// not a seventh way to report them.
public struct PaneHeaderAction: Sendable, Equatable {
    public let itemID: String
    public let value: String?

    /// `value` is bounded by the largest payload any header control can carry, a submitted
    /// `textfield`, so nothing unbounded rides back out of the renderer.
    public init(itemID: String, value: String? = nil) {
        self.itemID = itemID
        self.value = value.map { String($0.prefix(PaneHeaderItem.maximumTextFieldLength)) }
    }
}
