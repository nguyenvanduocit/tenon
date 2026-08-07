# Tenon documentation map

**Status:** canonical documentation index · **Reviewed:** 2026-08-06

This page tells readers which document owns a decision and which documents are current,
historical, or forward-looking. It is the first stop for architecture and implementation
work; [`../README.md`](../README.md) remains the product/build entry point.

## Precedence

When documents disagree, use this order:

1. [`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md) is
   normative for every interaction classification, public runtime path, intent audience,
   scoped facility, and control-plane operation.
2. Source-owned inventories and architecture fitness tests are the executable contract.
   A mismatch with the normative document is a defect; neither silently overrides the
   other.
3. Accepted design records specify their named mechanism or feature after the boundary law
   has classified it.
4. [`../VISION.md`](../VISION.md) owns product purpose and quality goals, not API spelling.
5. Guides and runbooks describe the current implementation. Research and historical audits
   provide evidence but are non-normative.

A new public `tenon` path, core intent, audience, facility, or control operation must update
the normative inventory, source inventory, fitness test, and superseded-path deletion in
one reviewed change.

## Current implementation guides

| Document | Owns | Status |
|---|---|---|
| [`plugin-author-guide.md`](plugin-author-guide.md) | authoring against the shipped JavaScript runtime | current |
| [`plugin-migration-v0.2.md`](plugin-migration-v0.2.md) | migration from deleted helper/command/sidebar APIs | current |
| [`operations.md`](operations.md) | build, test, state, troubleshooting, release verification | current |
| [`tdd.md`](tdd.md) | test-layer placement and runner coverage | current |
| [`development.md`](development.md) | native app setup, controls, source map, runtime overview | current |
| [`../Tests/TenonUITests/README.md`](../Tests/TenonUITests/README.md) | XCUITest accessibility identifiers and GUI requirements | current |

## Accepted architecture and designs

| Document | Decision scope | Implementation status |
|---|---|---|
| [`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md) | ordered interaction law and exhaustive inventories | normative, implemented |
| [`design-intent-bus.md`](design-intent-bus.md) | contracts, discovery, policy, provider lifecycle, admission | implemented; hard plugin isolation remains open |
| [`design-cli.md`](design-cli.md) | wire v2 and five-action CLI boundary | implemented |
| [`design-pane-slots.md`](design-pane-slots.md) | spatial workspace/pane model | implemented |
| [`design-pane-header.md`](design-pane-header.md) | the one chrome header a pane draws, its two slots, and its item vocabulary | implemented for built-in and plugin panes |
| [`design-command-palette.md`](design-command-palette.md) | plugin-owned intent projection and launchers | implemented |
| [`design-editor.md`](design-editor.md) | host-native editor, highlighting, state, external changes | implemented; large files remain bounded/refused |
| [`design-agent-lens.md`](design-agent-lens.md) | host-internal session/terminal projection | implemented for supported provider evidence; degrades explicitly |
| [`design-open-handlers.md`](design-open-handlers.md) | who opens a thing: published action, declared handler, approval, chooser, remembered default | accepted; not yet implemented (T-071) |
| [`design-automations.md`](design-automations.md) | manifest schedules and owner-scoped firing | implemented |
| [`design-plugin-builtins.md`](design-plugin-builtins.md) | exact JavaScript runtime vocabulary | implemented; normative surface companion |
| [`design-plugin-host-capabilities.md`](design-plugin-host-capabilities.md) | sensitive host operations and capability policy | implemented |
| [`design-plugin-settings.md`](design-plugin-settings.md) | declarative settings and browser settings | implemented |
| [`design-plugin-views.md`](design-plugin-views.md) | native declarative view tree | implemented |
| [`design-plugin-view-instances.md`](design-plugin-view-instances.md) | per-pane plugin view identity/lifecycle | implemented |
| [`design-diagnostics.md`](design-diagnostics.md) | what the app records about its own health, and what it deliberately never records | implemented (T-092) |
| [`design-pane-hosting.md`](design-pane-hosting.md) | a pane is sized by the canvas, never by its content | implemented (T-091) |

“Implemented” means the described path exists and is covered by the repository's test
layers. It does not claim the current dirty worktree is green; use command receipts from
[`operations.md`](operations.md) for that claim.

## Product and research

| Document | Use | Authority |
|---|---|---|
| [`../VISION.md`](../VISION.md) | product purpose, contract, success measures, roadmap | product direction |
| [`competitive-landscape.md`](competitive-landscape.md) | market/product comparison | research snapshot |
| [`research-human-agent-supervision.md`](research-human-agent-supervision.md) | Attention Inbox hypothesis and falsifiable metrics | research, not implementation |
| [`research-plugin-runtimes.md`](research-plugin-runtimes.md) | runtime/sandbox evidence gathered under the former Tessera name | historical, non-normative |
| [`research-reference-terminals.md`](research-reference-terminals.md) | engineering lessons from kero and muxy | historical, non-normative |
| [`naming.md`](naming.md) | naming decision and namespace evidence | historical decision record |
| [`superpowers/specs/2026-07-30-process-resource-monitor-design.md`](superpowers/specs/2026-07-30-process-resource-monitor-design.md) | process-resource monitor exploration | design snapshot; reclassify before implementation |

## Status discipline

- Do not put hard-coded test counts in durable docs. Record the command, worktree/commit,
  destination, result, and failures in the verification receipt.
- Mark future product targets explicitly; do not write them as shipped runtime capability.
- Keep old API spellings only inside clearly labelled historical/migration evidence.
- Update this table when a design ships, is superseded, or becomes historical.
- Research dates describe when evidence was gathered, not current third-party versions.
