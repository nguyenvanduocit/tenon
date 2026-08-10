# Changelog

This file records notable changes to Tenon. The project does not yet publish versioned
releases, so entries are grouped by date.

## 2026-08-10 — Release identity and signing

### Added

- A release pipeline: [`scripts/release.sh`](scripts/release.sh) builds universal, signs
  inside-out through [`scripts/release-sign.sh`](scripts/release-sign.sh), notarizes,
  staples, packages, and then verifies a copy extracted back out of the published archive.
  [`scripts/make-cask.sh`](scripts/make-cask.sh) derives the Homebrew cask from that
  artifact, and `.github/workflows/release.yml` runs both on a tag.
- `Tenon.entitlements`, granting `com.apple.security.cs.allow-jit` and nothing wider.
  `AppSigningFitnessTests` asserts that exact set, so widening it turns the suite red.
- [`docs/releasing.md`](docs/releasing.md) — the procedure, the one-time certificate and
  notarization setup, the CI secrets, and the measurements behind each decision.

### Changed

- The bundle identifier moved from `com.firegroup.tenon` to `dev.tenon.app`, joining the
  `dev.tenon.*` namespace the bundled plugins already publish under. macOS keys TCC consent,
  Keychain ACLs, LaunchServices registration, preferences and saved state to this
  identifier, so it was changed before the first release rather than after, when it would
  reset all of them for every user. The signing identity is a separate decision and did not
  change.
- Distribution builds enable the Hardened Runtime. Local installs deliberately do not:
  measured, an ad-hoc signature plus Hardened Runtime cannot load the app's own embedded
  frameworks, because Library Validation requires a shared Team ID that ad-hoc has none of.
- Both install paths sign innermost-first instead of with `codesign --deep`, which is not
  accepted for distribution. `--deep` remains correct on `codesign --verify`, where it means
  the opposite.

### Verified

- The Hardened Runtime does not restrict `libproc`: one probe binary signed twice, differing
  only in that flag, returned identical process telemetry. This closes the signed-app
  feasibility question the Resource Monitor design left open on 2026-07-30.
- JavaScriptCore keeps its JIT under Developer ID plus Hardened Runtime — a bundled plugin
  rendered byte-identical to the unhardened control.
- Notarization has **not** been submitted to Apple. Every step up to it is proved by a real
  signed universal artifact; the verdict is not.

## 2026-08-08 — Repository structure

### Changed

- Moved the Swift package from `poc/` to the repository root, so `Package.swift`, `Sources/`,
  `Tests/`, `plugins/`, `scripts/`, `Resources/`, `Vendor/`, `GhosttyKit/` and
  `Tenon.xcodeproj` sit where SwiftPM expects them. Every build, test and run command now
  executes from the root; the Xcode project's Swift package name changed from `poc` to
  `tenon` accordingly.
- Moved the package README to [`docs/development.md`](docs/development.md), the design system
  to [`docs/designs.md`](docs/designs.md), and the dated review artifacts to `docs/reports/`.
  Corrected the vendored reference checkout path to `references/`.
- Rewrote the documentation set, the agent instruction files and the task board to describe
  Tenon as the macOS application it is, replacing the proof-of-concept framing the tree
  carried from its first commit.

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
