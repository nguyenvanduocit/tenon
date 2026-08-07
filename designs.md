# Tenon design system

- **Status:** normative for host-native UI
- **Scope:** `poc/Sources/TenonApp` and every built-in macOS surface
- **Product anchor:** [`VISION.md`](VISION.md)

Tenon is a dense native supervision tool for people operating several terminal and agent
workstreams. It is not a marketing site, a mobile app enlarged for desktop, or a gallery of
feature-specific visual styles. The native host owns materials, typography, color, radii,
motion, density, and accessibility. A feature may introduce a new workflow; it may not
silently introduce a second design system.

This document records the visual contract. When a prototype, reference product, or mockup
disagrees with it, preserve the useful information architecture and rebuild the pixels in
Tenon's language.

## Sources of truth

Use these in order:

1. `TenonTheme.swift` for semantic color and font APIs.
2. Existing shared/native surfaces for component anatomy:
   - `LauncherMenu.swift` for compact popovers and search/results density;
   - `PaletteOverlay.swift` for full-window search and selectable rows;
   - `PluginUIPrompt.swift` for fields, text editors, buttons, and focused dialogs;
   - `PluginModalOverlay.swift` for modal framing;
   - `ContentView.swift`, `ShellTitleBar.swift`, and slot views for shell chrome.
3. This document for limits and review rules.
4. Prototypes and external products for structure and workflow only.

Do not copy external visual metrics. Do not derive a local palette or type scale inside a
feature when `TenonTheme` already owns that decision.

## Character

Tenon should feel:

- compact, calm, technical, and deliberate;
- native to macOS without becoming generic AppKit gray;
- terminal-adjacent without turning every label into monospace;
- information-dense without becoming cramped;
- accented by the user's Tenon accent, not painted with it.

The interface should recede behind the work. Hierarchy comes primarily from alignment,
spacing, typography, and contrast—not from making every concept a card.

## Semantic color

Always use `TenonTheme`; never add raw RGB/hex chrome colors in a feature.

| Token | Purpose |
| --- | --- |
| `ink` | deepest application background |
| `chrome` | shell and secondary chrome |
| `chromeRaised` | popovers, focused dialogs, raised controls |
| `panel` | recessed fields, editors, and contained work areas |
| `line` | separators and low-contrast borders |
| `text` | primary text |
| `muted` | metadata, helper text, inactive icons |
| `amber` | the live user-selected accent |

Rules:

- Apply `.tint(TenonTheme.amber)` at the root of a focused custom surface when native
  controls would otherwise fall back to macOS blue.
- Use the accent for current selection, focus, primary action, and small orientation marks.
- Do not assign decorative blue/orange/purple identities to feature modes. Additional
  colors require real status semantics such as success, warning, or destructive action.
- Large amber fills are exceptional. Most selected states use a restrained tint or one
  compact filled control.

## Typography

Use `TenonTheme.interfaceFont` for language and controls. Use
`TenonTheme.utilityFont` for commands, paths, counts, metadata, shortcuts, and compact
section labels.

| Role | Typical size |
| --- | ---: |
| utility metadata / uppercase section label | 8.5–10 |
| compact control / secondary text | 10.5–12 |
| body / row title / field value | 12–14 |
| dialog or panel title | 13–15 semibold |
| primary palette search | 16 |

Avoid 18–20 pt form fields and oversized feature titles. A focused desktop utility is not
a hero surface. Monospace is an information cue, not the default voice for prose.

## Density and geometry

Prefer the smallest size that preserves scanning, target acquisition, and the full default
state.

| Element | Contract |
| --- | --- |
| title bar | 36 pt |
| status bar | 24 pt |
| slot header | 31 pt |
| compact control | 28–32 pt |
| compact menu row | 28 pt |
| two-line utility row | 36–40 pt |
| compact popover | about 300–320 pt wide |
| focused dialog/editor | usually 480–560 pt wide; content-driven height, normally ≤520 pt |
| control radius | 6 pt |
| row/card radius | 7–8 pt |
| top-level modal radius | 12 pt |

Spacing uses a restrained scale: `2, 4, 6, 8, 10, 12, 14, 16, 18, 24, 32`.

- Use 4–10 pt inside compact controls and related groups.
- Use 12–18 pt for panel insets and gaps between form sections.
- Reserve 24–32 pt for genuinely spacious empty states or major composition boundaries.
- A simple editor should show all of its ordinary sections without scrolling. Scrolling is
  a fallback for constrained windows, accessibility scaling, or genuinely long content.
- Size result lists from their row count and cap them. Do not give a `ScrollView` only a
  generous `maxHeight`; popovers must not grow into empty sheets.

## Component anatomy

### Popovers and libraries

- Use the Launcher anatomy: compact header or 32 pt search row, 1 pt separator, exact-height
  results, and 28–40 pt rows.
- Prefer one leading icon, one strong label, muted metadata, and a trailing action.
- Empty states are short and operational. They explain the next action; they do not become
  mini onboarding screens.

### Forms and focused editors

- Use a 13–15 pt header and one short line of muted context.
- Field/control height is about 30 pt with a 6 pt radius.
- Use native segmented pickers for small exclusive choices.
- Use `panel` for recessed text fields and editors; use `chromeRaised` for the containing
  surface.
- Keep helper text adjacent to the control it explains.
- Footer actions follow `PluginUIPrompt`: muted secondary action, amber primary action,
  30 pt height, 6 pt radius.
- Use one containing panel only when it clarifies a real group. Avoid card-in-card layouts.

### Rows

- Rows are flat by default. Hover and selection create a quiet wash inside the surface.
- A badge must encode useful state such as recent, error, or scope. It is not decoration.
- Keep secondary actions in a trailing menu when they are not the row's primary verb.

### Modals

- A modal is only as large as its job. Start from content, not a standard canvas size.
- Use a 12 pt outer radius and one outer border/shadow treatment.
- Do not add an oversized icon badge, status capsule, and descriptive hero header to a
  routine edit form.

## Accessibility and input

- Every tappable control is a `Button`, `Toggle`, `Picker`, or another native control.
- Icon-only controls require an accessibility label and a help string.
- Decorative symbols and visual placeholder overlays are hidden from accessibility.
- Editors expose a concise label and a useful hint.
- Preserve keyboard focus, default/cancel actions, arrow navigation, and visible focus.
- Text and controls must remain legible at the user's accessibility settings; compact means
  efficient, not microscopic.

## Anti-patterns

Reject these in review:

- copying another product's modal pixel-for-pixel;
- inventing feature-local colors, fonts, radii, or a spacing scale;
- 20 pt form fields, 50–60 pt option cards, or 600×650 sheets for short desktop forms;
- stacking a card around every label/control pair;
- using a large illustration or icon badge to make a utility feel important;
- macOS-blue segmented controls inside an amber Tenon surface;
- hiding ordinary content below the fold because the header and gaps consumed the height;
- a one-row popover occupying its maximum list height;
- truncating explanatory copy that could be shorter;
- assuming UX quality excuses visual inconsistency.

## Canonical Runbooks example

The Runbooks revamp is the regression reference for this lesson:

- library width: 320 pt;
- editor: 480×460 pt;
- controls: 30 pt;
- control radius: 6 pt;
- command/brief editor: 76 pt in the default state;
- runner, place, and availability use native segmented controls with Tenon's accent;
- the full ordinary form, including the execution summary, is visible without scrolling;
- list height is calculated from its row count and capped at 280 pt.

These numbers are not a universal template. They demonstrate the rule: derive a compact
budget from nearby Tenon surfaces, centralize it, and verify it in the built app.

## Workflow before shipping UI

1. Read `VISION.md`, this file, and `TenonTheme.swift`.
2. Identify two or three existing Tenon surfaces with the same presentation role.
3. Write down a density budget before composing the view: width, ordinary height, control
   height, row height, inset, and radius.
4. Reuse semantic theme tokens and native controls.
5. Add a small pure regression test for important size/list calculations.
6. Build an isolated staging app and inspect real pixels at the actual window size.
7. Verify empty, populated, selected, disabled, long-copy, and alternate-mode states.
8. Inspect the accessibility tree, not only the screenshot.

## Review checklist

- Does this look like the Launcher, Palette, Plugin Prompt, and shell belong to the same app?
- Is every large dimension justified by content?
- Can any container, badge, helper line, or decorative color be removed?
- Is the normal state fully visible without scrolling?
- Do native controls use Tenon's accent instead of system blue?
- Are typography and radii taken from the shared language?
- Does the layout remain clear with long names and alternate modes?
- Are icon-only actions and editors correctly represented to accessibility?
- Was the built app inspected, rather than trusting the SwiftUI source alone?
