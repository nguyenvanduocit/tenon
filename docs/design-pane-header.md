# Pane header — one chrome header, two slots, one renderer

**Status:** implemented for built-in and plugin panes · **Reviewed:** 2026-08-07
**Normative boundary:** [`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md)

## Decision

A pane draws exactly ONE header, and the host draws it. It is the card's own chrome strip:
the glyph, the attention dot, the pane's name, and the ✕. Content that has something to say
about itself — its state, its path, its controls — contributes items into that strip as a
bounded VALUE, and the host decides how they are measured, folded, drawn, hit-tested and
cursored.

The value is `PaneHeader`, a `TenonCore` type with two slots. Both a built-in Swift pane and
a plugin fill it, by different mechanisms into the same value, and one renderer draws it.
That is invariant 6 satisfied rather than bypassed: a value type is not a mechanism, so a
built-in pane consuming `PaneHeader` is not impersonating a plugin, and a plugin publishing
one is not reaching into host UI.

It is also why no contributor needs a chrome bar of its own. Three `iconButton`s and a
flexible `textfield` are a browser toolbar; a `segmented` and a badge are a diff viewer's
controls. There is one way to draw a pane's chrome instead of one per kind of pane.

This design adds no public `tenon.*` path, core intent, audience, scoped facility, or
control-plane operation. `header` is a key inside a value already passed to `tenon.views.set`.

## Why a pane may draw only one

Vertical space in a supervision workspace is the scarce resource: a user watching six agents
pays every pane's chrome six times before reading a line of output. A second strip inside the
pane body also has no way to know what the first one says, so the two restate each other —
the pane's name above, the same file or branch below.

The header owns identity and state; the body owns content. A control that belongs to the pane
as a whole belongs in the strip. A control that belongs to something *inside* the pane — a
row, a hunk, a message — belongs beside that thing.

## Schema

Three value types in `TenonCore`, all `Sendable` and `Hashable`, none of which imports AppKit.

### `PaneHeader`

```swift
public struct PaneHeader: Sendable, Hashable {
    public static let maximumLeadingItems = 5
    public static let maximumTrailingItems = 8
    public static let empty = PaneHeader()

    public let leading: [PaneHeaderItem]     // packs left-to-right from the title origin
    public let trailing: [PaneHeaderItem]    // packs right-to-left from the close button

    public static func admitting(leading: [PaneHeaderItem] = [],
                                 trailing: [PaneHeaderItem] = []) -> Admission
    public init(leading: [PaneHeaderItem] = [], trailing: [PaneHeaderItem] = [])

    public var isEmpty: Bool
    public func item(id: String) -> PaneHeaderItem?
    public var flexibleItemID: String?
}
```

**Two slots, not three.** `leading` and `trailing` earn their names from genuinely different
layout rules: opposite pack direction, opposite fold order, and only one of them may hold the
flexible item. A third slot for verbs would render as the tail of `trailing` and carry no
distinct layout, fold, or hit-test rule — two names for one operation. Order inside `trailing`
(status first, controls last) expresses the same arrangement as position.

**There is no title slot.** The pane's name is host chrome (`SlotPresentation.title`) and
content may not replace it. Omitting the slot deletes a whole class of precedence rules before
anyone has to write them.

**`PaneHeader.admitting(leading:trailing:)` is the one policy path.** `PaneHeader.init`
delegates to it, and the storing initialiser is `private`, so nothing can put items into a
header without passing the rules.
It bounds each item first (`PaneHeaderItem.bounded()`), then the slot — in that order, so a
malformed item never consumes one of the five or eight places a usable item could have taken —
and settles identity across BOTH slots at once, because both ends of the contract key on the
id alone: the renderer draws a run with one `ForEach(id: \.item.id)`, and a click comes back
carrying nothing but an `itemID`.

`admitting` returns what it refused, in the order the producer wrote it, so a decoder can say
what happened:

```swift
public struct Admission: Sendable, Hashable {
    public let header: PaneHeader
    public let refused: [RefusedItem]        // empty is the ordinary case
}
public enum Slot: String, Sendable, Hashable { case leading, trailing
    public var capacity: Int }
public struct RefusedItem: Sendable, Hashable {
    public let slot: Slot
    public let id: String
    public let reason: Refusal
}
public enum Refusal: Sendable, Hashable {
    case duplicateID     // an item admitted before it, in either slot, holds that id
    case slotIsFull      // its slot already holds as many items as a slot may hold
}
```

A malformed item is not a `RefusedItem`: it never reaches admission, and the boundary that
decoded it already explained it in the vocabulary of the field the author got wrong.

`item(id:)` exists for the ROUTER, not the renderer. A `PaneHeaderAction` carries an `itemID`
and nothing else, while which contract the click travels back on — a selection or a commit —
is a property of the item's KIND. Asking the header what it published is how the router
answers that without every producer having to set a second discriminator correctly.

### `PaneHeaderItem`

Flat and non-recursive. A 34-point strip has no meaning for `scroll`, `grid`, `card`,
`webview`, or a nested stack, so the vocabulary makes those states *unrepresentable* rather
than filtering them at parse time — an author never has to learn which two thirds of the body
vocabulary are silently dropped up here.

| case | identity | payload | interactive |
|---|---|---|---|
| `dot` | `id` | `tint`, `tooltip?` | no |
| `label` | `id` | `text`, `weight`, `color`, `truncation`, `tooltip?` | no |
| `badge` | `id` | `text`, `tint`, `tooltip?` | no |
| `image` | `id` | `systemName`, `tint`, `tooltip?` | no |
| `spinner` | `id` | — | no |
| `iconButton` | `id` | `systemName`, `tint`, `isEnabled`, `tooltip?`, `accessibilityID?` | yes |
| `toggle` | `id` | `systemName`, `isOn`, `isEnabled`, `tooltip?`, `accessibilityID?` | yes |
| `segmented` | `id` | `segments[2…5]`, `selection`, `isEnabled`, `accessibilityID?` | yes |
| `menu` | `id` | `systemName`, `entries[1…12]`, `isEnabled`, `tooltip?`, `accessibilityID?` | yes |
| `textfield` | `id` | `value`, `placeholder`, `flex`, `isEnabled`, `accessibilityID?` | yes |

`isInteractive` is a real invariant, not a convenience: every point in the header that is not
the close control and not an interactive item's rect must still start a pane drag, so the set
of items answering `true` is exactly the set of holes punched in the drag surface. A dot, a
label, a badge, an image and a spinner stay drag surface.

`toggle`'s `isOn` is the item's own current state, not the next one; the owner flips it.
`textfield` is the one editable control and the one item that may absorb slack; it commits
through SUBMIT rather than select.

### Bounds

Every bound is applied by `PaneHeaderItem.bounded()`, which `admitting` runs over every item
it accepts. Both producers reach their header through it, so a built-in Swift pane cannot
publish a 400-character label a plugin would have been clamped out of (invariant 10).

Bounds come in two flavours, and which one applies is a judgement about *identity*:

- **Display text truncates.** A label, a badge, a tooltip and a field's value are read by a
  human; a shortened one still says roughly what it said.
- **Identity drops its item.** An `id`, a `systemName`, a `selection`, a segment's `value` and
  a menu entry's `value` are routed and resolved on. A truncated identifier would silently
  name a different control, merge two of them, or report a value its owner never published, so
  one that does not fit is refused rather than mangled.

| bound | value | applies to |
|---|---|---|
| `PaneHeader.maximumLeadingItems` | 5 | items in `leading` |
| `PaneHeader.maximumTrailingItems` | 8 | items in `trailing` |
| `PaneHeaderItem.maximumIdentifierLength` | 64 | `id`, `systemName`, `selection` |
| `PaneHeaderItem.maximumLabelLength` | 200 | a `label`'s `text`, a field's `placeholder` |
| `PaneHeaderItem.maximumBadgeLength` | 24 | a `badge`'s `text` — it CUTS rather than ellipsising |
| `PaneHeaderItem.maximumTooltipLength` | 1024 | every `tooltip` |
| `PaneHeaderItem.maximumTextFieldLength` | 2048 | a field's `value`, and a `PaneHeaderAction`'s `value` |
| `PaneHeaderSegment.minimumSegments` / `maximumSegments` | 2 / 5 | a `segmented`'s options |
| `PaneHeaderSegment.maximumLabelLength` | 32 | a segment's `label` and spoken name |
| `PaneHeaderMenuEntry.maximumEntries` | 12 | a `menu`'s lines |
| `PaneHeaderMenuEntry.maximumLabelLength` | 64 | an entry's `label` |

The tooltip bound is the only one that buys no layout: AppKit wraps a help string and no
control gets narrower because it is long. It is sized by the longest thing a pane has to be
able to SAY — `PATH_MAX` on Darwin — so a message can always at least carry the longest name
macOS can give the thing it is about.

An item is refused outright when its `id` is empty, over-long, or reserved to the host; when a
glyph-bearing item names no drawable symbol (an `iconButton` with no glyph is an invisible
clickable rectangle); when a `segmented` is left with fewer than two usable options; or when a
`menu` has no entries.

### Reserved identity

```swift
public static let overflowItemID = "tenon.paneHeader.overflow"
public static let reservedIDs: Set<String> = [overflowItemID]
```

The `…` control is the one item the host composes for itself, after both runs are settled, so
it never passes through `admitting` — which is exactly what lets its id be reserved against
every contributor without unmaking the host's own. `bounded()` refuses a reserved id, so an
item wearing it is dropped at construction rather than documented against. The refusal is
structural: such an item would have its clicks resolved as picks in the host-composed overflow
menu and dropped, and it would put two rows under one key in the single `ForEach` that draws a
run.

### `PaneHeaderSegment` and icon-only options

A segment shows `systemName` when it has one and `label` otherwise. An icon-only segment is
the only control in this vocabulary that draws no text, and two readers need some: the pointer
wants hover text, VoiceOver wants a spoken name. They are the same sentence, so a segment takes
it from whichever side its author wrote it on and fills the other in. Writing both keeps both —
the fallback fills a gap, it never overrules a choice — and a segment that already SHOWS its
name synthesises nothing, because a tooltip repeating the text under the pointer is noise.

An icon-only segment given neither still keeps its place, degrading to its `value`: refusing it
would starve its picker below two options and delete the whole control, while a visibly wrong
`"seg-a"` in the hover text is the mistake reporting itself. That is the trade the vocabulary
makes wherever it can — **refuse what cannot be DRAWN, degrade what cannot be READ.**

### `PaneHeaderAction`

```swift
public struct PaneHeaderAction: Sendable, Equatable {
    public let itemID: String
    public let value: String?     // a segment/menu value, or a field's submitted text
}
```

One struct for all ten kinds, because the click that comes back out of a header is the same
EVENT fact as a row click or a body button click. The header adds a place to put controls, not
a seventh way to report them.

## Interaction classification

[`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md) is applied
in order, stopping at the first match. The two producers land on different rungs, and that is
the design rather than an exception to it.

### The plugin path — rung 1, CONTRIBUTION

A plugin is an independently owned semantic owner: each `PluginID` is separately installed,
disabled, and hot-reloaded. `header` is an authoritative snapshot, not a command — the plugin
owns which items exist, their ids, labels, and selection; the host owns decoding, fail-soft
validation, token resolution, measurement, geometry, folding, drawing, hit testing, cursor
rects, and every native object. Repeated publication replaces the plugin's previous header for
that view, and hot reload removes a retired generation's header atomically, because
`PluginHost.publish()` rebuilds its contribution list from live sessions only.

It is not EVENT: state is being declared, not reported. Not RESOURCE/STREAM/TASK: no handle,
no cancel, no lifetime past the snapshot. Not DIRECT: a plugin is a different semantic owner.
Not SCOPED FACILITY: that allowlist is closed to settings, plugin-private storage, and log.
Not INTENT: a snapshot has no result cardinality and exercises no cross-principal authority.

Decoding performs **no imperative mutation** — it is pure value mapping. That is why
`PluginRuntimeValueParsing` carries its diagnostics OUT as a value (`PluginParsedHeader`)
rather than writing them: a plugin's log is a host facility, not a value, and the parser is
not the layer allowed to touch it. `PluginRuntime` — which knows who published and into which
view — emits the lines.

The click that comes back is not a seventh mechanism. A callback delivered through
`tenon.views.onSelect` is an EVENT fact, the same fact a row click, a body button click and a
row context-menu pick already are.

### The host-native path — rung 4, DIRECT

`TenonCore`, `TenonApp` and their built-in Swift services are ONE semantic owner, and a pane's
own chrome crosses no public adapter boundary. A content view writing a `PaneHeader` into
`PaneHeaderStore`, and a `PaneHeaderCommand` coming back, are typed same-owner calls. No
`IntentValue` is serialised, no dispatcher is called, no principal is minted.

The precedent is exact and already in the DIRECT inventory: pane activity/attention state
(T-029) is read same-owner DIRECT by tab chips, pane headers, sidebar rollups and the
title-bar count.

### One value, two mechanisms

```text
built-in Swift pane ──────────────────► PaneHeaderStore (typed service)
plugin ─► views.set `header` CONTRIBUTION ─► PluginViewSection.header
                              both ─► PaneHeaderProjection ─► PaneHeaderBar (one renderer)
```

There is exactly one public protocol for a contributor to draw a pane header (the `header`
key) and exactly one renderer.

### What stays out

A focused-view control that moved its pixels into shared chrome keeps its ownership. Such a
control is view-local with no public command registration; promoting one to a registered,
discoverable, or rebindable product keybinding would cross invariant 8. Moving a control's
pixels does not change who owns it.

## Geometry and overflow

`PaneHeaderLayout.solve` is a pure function — it reads no global, mounts no view, caches
nothing, and takes its width measurement through an injected `PaneHeaderMetrics` so tests solve
against fixed widths and the shell solves against real font metrics. Hit testing, cursor rects,
the drag band and the renderer all read the ONE `Solution` it returns, so a solved rect and the
painted control cannot drift apart.

| constant | value | what it guarantees |
|---|---|---|
| `TenonTheme.slotHeaderHeight` | 34 | the strip's height |
| `accessoryOriginFloor` | 31 | `x ∈ (12, 31)` is provably bare, always-draggable header at every width with any content |
| `closeButtonReserve` | 31 | nothing is ever placed under the ✕ |
| `minimumDragBand` | 64 | the bare band reserved BEFORE any accessory is placed |
| `groupGap` | 8 | the floor the band relaxes to once nothing foldable is left |
| `northResizeEdge` | 6 | mirrored from `SpatialCanvasInteractionCoordinator.hitRegion` |
| `verticalInset` | 7 | applied top and bottom, so `minY > northResizeEdge` follows arithmetically |
| `accessoryHeight` | 20 | 34 − 2 × `verticalInset`; shrinks with the header rather than spilling into the resize edge |
| `trailingRunShare` | 0.55 | the share of the card the trailing run may take before it folds |
| `minimumTitleWidth` | 40 | below this the title is dropped rather than shown as an ellipsis |
| `minimumLabelWidth` | 24 | a label gives up width to here before anything folds |
| `minimumTextFieldWidth` | 48 | a field shrinks to here; it never folds |
| `overflowWidth` | 22 | the `…` control |

An **empty header solves to the bare chrome at every width** — the title owns the whole span —
which is the receipt that a pane contributing nothing pays nothing.

### The overflow rule

The smallest pane a user can create is 3 of 12 columns, so narrow is the common case in
multi-agent supervision and the rule is explicit, deterministic, pure, and asserted headlessly.
Every step is a **fold into an overflow menu, never a scroll** — a header that scrolls
horizontally is a header nobody can use.

1. **Reserve first, place second.** The drag band is subtracted from the available span before
   any accessory is placed, and `x ∈ (12, 31)` is reserved unconditionally. The pane's grab
   handle is a layout constraint, not a residual. **There is no priority or pinning token**:
   nothing a contributor can write exempts an item from folding, so a plugin can never render
   its own pane immovable, un-right-clickable, or immune to fill-width.
2. **The trailing run folds from its leftmost item inward** once it exceeds `trailingRunShare`
   of the card. The rightmost controls are what the eye and the muscle memory find first.
3. **The leading run folds from its last item backwards** until the band's reservation holds.
   Folding is re-evaluated in that order on every pass, because folding a leading item
   introduces the `…` into the trailing run and can push it back over its share. Each pass
   removes exactly one item, so the loop is bounded by the item caps the value type enforces.
4. **Nothing folds silently.** Everything folded appears in one `…` menu at the trailing edge:
   a folded `segmented` becomes its options as entries with a checkmark on the selected one, a
   folded `toggle` becomes one checked entry, a folded `iconButton` or `menu` becomes its
   entries, and a folded `label` or `badge` folds in as a read-only line. A `dot`, an `image`
   and a `spinner` are decoration and simply disappear. Overflow entries speak the *source
   item's* value space, so the solver keeps each folded item paired with the entries it
   contributed and `Solution.overflowAction(forEntryValue:)` attributes a pick back to it.
5. **A `label` truncates instead of folding**, per its own `truncation` token, down to
   `minimumLabelWidth`. Which end gives way is the label's own say; a path set to `head` keeps
   its meaningful tail. The renderer — the layer that knows how to shorten a path — applies it.
6. **A `textfield` never folds.** A menu entry reports one fixed value and cannot accept
   typing, so a field has no honest folded form; it shrinks to `minimumTextFieldWidth` instead.
   A flexible one takes the gap and suppresses the title. At most one per header — the first
   claimant wins, and later ones lay out at their natural width.
7. Once nothing foldable is left, the band gives up its reservation to `groupGap` rather than
   clipping a control that has nowhere to go.

Solver post-conditions, each with its own test, swept across every width a pane can take: no
placement left of `accessoryOriginFloor`; none right of `width − closeButtonReserve`; none
inside the north resize edge or the corner squares; no two placements overlap; the drag band is
contiguous and non-empty. `PaneHeaderLayoutTests` pushes every placement corner through the
real `SpatialCanvasInteractionCoordinator.hitRegion` rather than asserting the solver's own
constant back at itself.

### Rendering and hit testing

`SpatialSlotCardView` hosts **two** `PaneHeaderHostView`s — one per run — with a bare AppKit
band between them. Two hosts make the pane's drag surface a single contiguous rectangle by
construction rather than a rect subtraction, and keep the drag path off SwiftUI's hit-test
propagation across the AppKit boundary. Each host answers `hitTest` only for the rects the
solver placed a control in and declines everything else, because SwiftUI's `Color.clear` IS
hit-testable and would otherwise swallow the gaps.

Consequences the card preserves: pane drag, resize, double-click fill-width, and the ✕ behave
as they do without a header. A right-click over a control returns no pane menu (the control
gets AppKit's own, or none); the bare band still offers the pane menu. Because cursor rects now
depend on CONTENT rather than only on `bounds`, `layout()` invalidates them whenever the
solution changes.

**A header control focuses its pane before it acts; the ✕ is the documented exception.**
Everything else in the strip hands the pane's own state a change, and a change made to a pane
AppKit does not consider focused leaves `activeSlotID` pointing elsewhere — ⌘W would close the
wrong pane.

Header state is pane state, not content identity, and is deliberately not folded into the
card's content cache key. Folding it in would tear down and rebuild the `NSHostingView` that
owns the live Ghostty PTY or `WKWebView` on every status tick.

## The plugin-facing API

### Manifest

**No change.** Views are runtime-declared; a header is part of a view and its lifetime IS the
view's lifetime. UI contribution stays permission-free, because it is declarative plugin-owned
data validated and rendered by the host.

### `tenon.views.set`

Unchanged signature: `tenon.views.set(viewID, specification, instanceID?)`. The `header` key
sits beside `items` or `body` and reaches a rows pane and a body pane alike.

```js
tenon.views.register("explorer", { title: "Explorer", instanced: true });

tenon.views.set("explorer", {
  // The PANE NAME. The chrome header owns it; header items sit beside it, never replace it.
  title: tenon.path.basename(state.root),

  header: {
    leading: [
      { type: "dot",   id: "state", tint: "green", tooltip: "Clean working tree" },
      { type: "label", id: "root",  text: state.root, color: "muted", truncation: "head" },
      { type: "badge", id: "count", text: String(state.changed), tint: "muted" }
    ],
    trailing: [
      { type: "segmented", id: "layout", selection: state.layout,
        segments: [
          { value: "tree", systemName: "list.bullet.indent", tooltip: "Tree" },
          { value: "flat", systemName: "list.dash",          tooltip: "Flat" }
        ] },
      { type: "toggle", id: "hidden", systemName: "eye", isOn: state.showsHidden,
        tooltip: "Show hidden files" },
      { type: "iconButton", id: "reveal-root", systemName: "arrow.up.forward.app",
        tooltip: "Reveal in Finder", isEnabled: !state.isLoading },
      { type: "spinner", id: "loading" }        // publish it only while loading
    ]
  },

  items: rows
}, instanceID);

// ONE handler — the same one a row click, a body button and a row context-menu pick use.
tenon.views.onSelect("explorer", function (itemID, value, instanceID) {
  if (itemID === "layout")      return setLayout(instanceID, value);   // "tree" | "flat"
  if (itemID === "hidden")      return toggleHidden(instanceID);       // owner flips isOn
  if (itemID === "reveal-root") return revealRoot(instanceID);
  return openRow(itemID);
});

// A header textfield commits through onSubmit, exactly like a row's inline rename.
tenon.views.onSubmit("explorer", function (itemID, text) {
  if (itemID === "go") return navigate(text);
});
```

| `type` | required | optional | reports through |
|---|---|---|---|
| `dot` | `id` | `tint`, `tooltip` | — |
| `label` | `id`, `text` | `weight`, `color`, `truncation`, `tooltip` | — |
| `badge` | `id`, `text` | `tint`, `tooltip` | — |
| `image` | `id`, `systemName` | `tint`, `tooltip` | — |
| `spinner` | `id` | — | — |
| `iconButton` | `id`, `systemName` | `tint`, `isEnabled`, `tooltip` | `onSelect(id, null)` |
| `toggle` | `id`, `systemName` | `isOn`, `isEnabled`, `tooltip` | `onSelect(id, null)` |
| `segmented` | `id`, `segments[2…5]`, `selection` | `isEnabled` | `onSelect(id, segment.value)` |
| `menu` | `id`, `systemName`, `entries[1…12]` | `isEnabled`, `tooltip` | `onSelect(id, entry.value)` |
| `textfield` | `id` | `value`, `placeholder`, `flex`, `isEnabled` | `onSubmit(id, text)` |

A segment takes `value` plus `label` or `systemName`, and optionally `tooltip` and
`accessibilityLabel`. A menu entry takes `value` and `label`, and optionally `systemName`,
`isOn` and `separatorBefore`.

Tokens follow the existing enum-token discipline: `tint`/`color` ∈
`{default,text,muted,amber,green,red}`, `weight` ∈ `{regular,medium,semibold}`, `truncation` ∈
`{head,middle,tail}`. **An unknown token degrades to its documented default and never drops the
item** — a typo costs a label the end it wanted shortened, never the label itself.

**Omitting `header` clears the previous one**, the way omitting `modal` closes a sheet. An
absent, null or non-object `header` is how a plugin takes a control away: the published state
IS the state, so anything the plugin stopped saying it stopped meaning.

**`accessibilityID` is not decodable from plugin JSON.** An accessibility identifier is
XCUITest identity, not contributor data, and a contributor able to mint one could rename the
host's own test anchors out from under the UI suite. Built-in producers set it.

### What a malformed header gets back

One bad item costs that item its place; the other nine are drawn, the view is published, and
the plugin stays active. A header is a strip of independent controls, and blanking the whole
strip over one of them would take away the nine that were fine.

Every way an item can be lost is a sentence in the plugin's own log, naming the slot, the item,
and what went wrong in the author's vocabulary — a missing required field, an id already spoken
for, a full slot, or an unknown `type`. The lines are capped at
`PluginParsedHeader.maximumDiagnostics` (16), sized just above the thirteen items a header can
hold: a plausible mistake is named in full, an implausible one is counted. The cap exists
because each line is delivered by launching a host task and that ledger is finite; an
all-malformed header would otherwise saturate it and start dropping the very diagnostics the
channel exists to deliver.

### Known limitation

Header item ids share one namespace with row ids and body action ids inside a view. Ids must be
unique per view. A discriminator would be a public-surface change for a problem that has not
yet bitten.

## The host-native path

`PaneHeaderStore` (`TenonApp`, `@MainActor @Observable`) is where a built-in pane's header lives
while its content view is mounted. Data goes UP as a value; commands come DOWN as a typed
`PaneHeaderCommand`. Every content view keeps the state it owns — Diff's `style`, Changes'
`layout` — so this moves pixels, not ownership.

```swift
private(set) var headers: [UUID: PaneHeader]                  // the observed input
func publish(_ header: PaneHeader, for slotID: UUID)          // equality-guarded
func onCommand(for slotID: UUID, _ handler: @escaping (PaneHeaderCommand, String?) -> Void)
func perform(_ command: PaneHeaderCommand, value: String?, for slotID: UUID)
func clear(for slotID: UUID)                                  // the primary release, from .onDisappear
func scheduleSweep(retaining slotIDs: Set<UUID>)              // backstop; see below
```

`clear(for:)` from a publisher's `.onDisappear` is the primary, symmetric release.
`scheduleSweep(retaining:)` catches only a content view torn down without one, and it is
scheduled rather than immediate for a specific reason: the canvas asks for it from
`SpatialCanvasNSView.configure`, which SwiftUI reaches through `updateNSView` — the middle of a
view update, where mutating observable state is the "Modifying state during view update"
defect. The DECISION is taken synchronously, because reading is always legal; the WRITE it
implies is scheduled onto the main actor and lands after the update that asked for it. Nothing
can render the difference, because the same pass has already removed that slot's card. The
task is held rather than fired and forgotten, so a second configure pass replaces an unstarted
sweep with its newer slot set instead of racing it, and a test can await the deferred write.

**`WorkspaceStageView.body` reads `paneHeaders.headers`. That read IS the invalidation
contract** — the sixth observed input beside `pool.paneAttention`, passed down as a value
dictionary. Without it every built-in header would freeze at its first value, because the
canvas is reached only from `updateNSView`, which SwiftUI calls only when that body
re-evaluates. Publishing happens from `.onChange`/`.task`/`.onAppear`, never from a `body`; the
equality guard makes a duplicate publish a true no-op, so an accidental in-body write terminates
after one pass instead of looping.

Plugin panes are deliberately NOT in the store. Their header rides `PluginViewSection`, which
the host rebuilds from live sessions, so a retired generation's header vanishes with its
contributions and nothing has to sweep after it (invariant 10). `PaneHeaderProjection.header`
is an exhaustive `switch` over slot content rather than a `?? .empty`, so adding a kind of pane
forces its author to say which owner supplies its header.

`PaneHeaderCommand` is what keeps the built-in half typed: a projection mints an item id only
from a case's `rawValue`, and the router resolves an id only back into a case, so no free-form
string routes between two parts of the one host semantic owner. Each payload is minted from the
owning view's own `RawRepresentable` enum (`DiffStyle: String`, `ChangesLayout: String`), so the
two ends cannot drift.

```swift
enum PaneHeaderCommand: String, CaseIterable, Sendable {
    case diffStyle     = "diff.style"       // a DiffStyle raw value
    case changesLayout = "changes.layout"   // a ChangesLayout raw value
    case changesRefresh = "changes.refresh" // no value
    case agentLensPresentation = "agentLens.presentation"  // an AgentLensPresentation raw value
    case agentLensInspector    = "agentLens.inspector"     // no value
}
```

A pane whose header is pure status — a badge, a dot, a spinner — publishes no interactive item
and needs no case.

## What each pane publishes

| pane | leading | trailing |
|---|---|---|
| Agent Lens | status `dot`, provider `label`, status `label`, amber warning `image` when there are diagnostics — all four only once an agent is detected | `segmented` session/terminal/split-icon, inspector `toggle` |
| Diff | `+N` / `−M` badges when loaded, non-binary and changed | `segmented` unified/split |
| Changes | branch glyph, branch label, total badge | `segmented` tree/flat, refresh `iconButton` (only with auto-load, disabled while loading) |
| Docs | — | `spinner` while loading |
| File | — | exactly one of error badge / conflict badge / dirty dot |
| Automation | clock `image`, schedule-count badge when non-zero | scheduled/paused state badge |
| Browser plugin | back / forward / reload `iconButton`s | flexible address `textfield` |
| File-explorer plugin | root `label`, truncating `head` | reveal-in-Finder `iconButton` |
| Kanban plugin | board-path `label` | — |
| Empty | — | — |

A pane that publishes nothing gets `PaneHeader.empty` and the bare chrome, with both hosts
hidden and the whole strip drag surface. A terminal pane with no agent detected in it is
exactly that case, so a plain shell pays nothing for a feature it is not using.

Agent Lens keeps one thing in its body that the strip cannot hold: the context-and-evidence
inspector is a panel with a click-outside scrim, clamped to 420 points and to the pane's own
height. A `PaneHeader` is a bounded value and cannot carry an `AgentLensSnapshot`, so the
evidence stays where the data is and the chrome toggle only says whether the panel is open.
Its `isOn` and the timeline row that raises it read the same two properties on
`AgentLensViewModel`, which is why they are pane state rather than view state.

## Verification

| claim | evidence |
|---|---|
| bounds are enforced identically for both producers | `PaneHeaderTests` |
| the plugin contract round-trips through the real JS runtime | `PaneHeaderSchemaTests` |
| the surface did not grow | `testRuntimeExportsOnlyTheClassifiedPublicSurface` and `testPluginGlobalScopeClosesToBuiltinsHostHooksAndTenon` pass **unmodified** |
| the solver's post-conditions hold at every width | `PaneHeaderLayoutTests` |
| the store does not mutate when nothing changed | `PaneHeaderStoreTests` |
| a plugin pane reads its own instance section and never another's | `PaneHeaderProjectionTests` |
| a plugin header action routes through `invokeViewSelect`/`invokeViewSubmit` | `PluginPaneHeaderRouteTests` |
| an accessory takes its own click while every other point of the strip still drags, resizes, or offers the pane menu | `SpatialCanvasInteractionTests`, `SpatialCanvasGestureTests` |
| exactly one implementation draws a pane header | `testExactlyOneImplementationDrawsAPaneHeader` |
| superseded paths cannot return | `testSupersededPaneHeaderPathsAreGoneFromShippedCode` |
| the header stays CONTRIBUTION + DIRECT | `testPaneHeaderCodeStaysContributionAndDirect` |
| built-in ids are minted from the typed enum only | `testBuiltInHeaderItemsNeverMintRawActionStrings` |
| Agent Lens says nothing until an agent is detected, and its picker's three states map onto the pane's two renderer properties | `AgentLensPaneHeaderTests` |
| this document states the shipped schema | `testPaneHeaderDocumentStatesCurrentSchema` |

The GUI cannot be screenshotted from a headless shell, so the one thing no headless test proves
is that a `.controlSize(.small)` segmented picker in a 34-point AppKit-hosted strip takes a
click. `TENON_DIFF_SNAPSHOT` and `TENON_CHANGES_SNAPSHOT` render the same `PaneHeaderBar`
through the same projection and solver offscreen, which is the closest standing evidence.

## Residual risks

1. **The invalidation channel is the whole host-native design.** If `WorkspaceStageView.body`
   stops reading `paneHeaders.headers`, every built-in header freezes at its first value. It is
   the single line that must not be dropped in review.
2. **Churn.** A header change re-runs the canvas configure pass for the whole tab. This is the
   same exposure `host.pluginViews` and `pool.paneAttention` already carry, bounded by the item
   caps and the equality guards, but a plugin republishing at 10 Hz pays it.
3. **Publishing from a `body`** is a SwiftUI runtime warning the compiler will not stop us
   making. The equality guard bounds the damage; the rule is enforced by review.
4. **`accessibilityID` is host-only**, so no plugin header control is XCUITest-addressable.
   Accepted deliberately. It is also an ITEM field and not a SEGMENT one, so an individual
   option inside a `segmented` is reachable by its spoken name but carries no identifier of its
   own. Agent Lens's split option is the first control that had one; the picker around it keeps
   `tenon.agentLens.mode` and the option keeps a spoken name, which no shipped test read.
5. **Narrow panes fold rather than show.** A 320-point agent pane puts its status labels in the
   `…` menu, one click away instead of in view. The escape, if it reads badly in practice, is
   icon-only segments before folding, which `PaneHeaderSegment` already supports.
6. **Right-click over a control offers no pane menu.** Correct for a text field, consistent
   with the ✕, but a user could notice it on a segmented picker.
