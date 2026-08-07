# Changelog

This file records notable changes to Tenon. The project is pre-alpha and does not yet
publish versioned releases, so entries are grouped by date.

## 2026-08-07 — Runtime hardening and architecture consolidation

### Added

- Added one shared pane-header model and renderer for built-in and plugin panes, including
  bounded layout, keyboard-accessible actions, quick commands, and Agent Lens controls.
- Expanded Agent Lens with hook-first Claude Code events, Markdown rendering, verified file
  links, launch suggestions, and explicit degraded states when authoritative session evidence
  is unavailable.
- Added a staging app installer, macOS CI, Ghostty artifact integrity tests, a canonical
  documentation index, operator and plugin-author guides, API migration notes, and enforced
  source-domain tags.
- Added query-only intent-provider resolution, pane-owner lookup, directory metadata, plugin
  open-handler approvals, and terminal job termination when a pane closes.

### Changed

- Consolidated finite cross-boundary work on the intent system and reduced the public plugin
  runtime to its classified paths, scoped facilities, resource lifecycles, and control-plane
  operations. Removed superseded command, capability, and sidebar APIs.
- Moved CLI wire actions and framing into `TenonIntentCore`, leaving the shipped CLI independent
  of host-domain code, and isolated production and staging instances by bundle identity and
  runtime channel.
- Replaced the stateful staged-write cursor with one bounded atomic file-write request and
  promoted directory listing to its new metadata-bearing contract.
- Made workspace persistence, plugin inventory precedence and trust, provider selection,
  automation delivery, runtime task ownership, diff projection, and network classification
  fail closed and explicitly bounded.

### Fixed

- Hardened CLI socket ownership, stale-socket recovery, activation races, slow-client handling,
  request deadlines, and off-main response writes.
- Prevented stale async image, web, diff, hook, and runtime results from publishing after their
  owning generation or pane has changed; cancellation now joins owned work during teardown.
- Corrected special-use IP blocking, plugin installation consent rotation, local HTML loading,
  browser user-agent and popup behavior, Agent Lens mode persistence, and several SwiftUI
  accessibility and Reduce Motion regressions.

### Documentation

- Made the interaction-boundary law normative and exhaustive across direct calls, intents,
  events, contributions, scoped facilities, resources, streams, tasks, and control operations.
- Reconciled the README, vision, feature designs, TDD guidance, plugin documentation, operations
  runbook, and architecture fitness tests with the implemented system.
- Documented two remaining structural limits: JavaScriptCore is not a hard security sandbox,
  and the legacy plugin-private process stream still lacks race-free process-group ownership.
