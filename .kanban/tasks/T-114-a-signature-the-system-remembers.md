# T-114: A signature the system remembers
> The app is ad-hoc signed, so every install is a different app to macOS: TCC grants reset
> and Keychain items lose their owner. Turn on the Hardened Runtime a real identity will
> require, and prove it costs neither JavaScriptCore nor `libproc` before anyone ships it.

- **priority**: high
- **effort**: M
- **prd**: TENON-PRD-015 (release/signing pipeline), TENON-PRD-016 (signed-app feasibility
  for process telemetry)

## Why

`codesign -dv /Applications/Tenon.app` reports `flags=0x2(adhoc)`, `TeamIdentifier=not set`.
An ad-hoc signature is a content hash, so it changes on every build. macOS keys both TCC
consent and Keychain ACLs to the code identity, which means:

- every `./install.sh` re-asks for Documents/Desktop/Downloads the moment a PTY child
  touches them, because the previous grant belonged to a signature that no longer exists;
- `SecretStore` (`Sources/TenonCore/SecretStore.swift:111`, `kSecClassGenericPassword` with
  no access group) writes items whose ACL names an app identity the next install lacks.

`docs/operations.md:141-142` already requires sign → `codesign --verify --deep --strict` →
notarize → staple for a release, and that checklist has never had an implementation.

## The open question this closes

`docs/superpowers/specs/2026-07-30-process-resource-monitor-design.md:91-95` records the
Resource Monitor's outstanding gap verbatim: the app "is ad-hoc signed with no sandbox and
no hardened runtime … so no entitlement can restrict `libproc` here. That reasoning is sound
but is not the same thing as a Release receipt." PRD-016 carries it as *signed-app
feasibility*.

The key fact that makes this task possible without a Developer ID certificate: **Hardened
Runtime is a code-signing flag the kernel enforces regardless of who signed** — `--options
runtime` applies to an ad-hoc signature too. So the entitlement question can be measured
now, on this machine, and the certificate becomes a separate, smaller step.

`docs/research-plugin-runtimes.md:745,994` is the other half: under Hardened Runtime,
JavaScriptCore needs `com.apple.security.cs.allow-jit`, and the escape entitlements form a
widening cascade (`allow-jit` → `allow-unsigned-executable-memory` →
`disable-executable-page-protection`) of which **exactly one** may be set.

## Criteria

- [ ] `Tenon.entitlements` grants `com.apple.security.cs.allow-jit` and nothing wider — no
      `allow-unsigned-executable-memory`, `disable-executable-page-protection`,
      `disable-library-validation`, `allow-dyld-environment-variables`, or `get-task-allow`
- [ ] A fitness test asserts that exact set, so a later widening turns the suite red
- [ ] Release builds enable Hardened Runtime and carry the entitlements file
- [ ] **Live receipt, not an assertion**: the hardened Release app launches, a bundled plugin
      evaluates JavaScript, and the Resource Monitor still attributes PTY processes —
      captured as command output
- [ ] `scripts/notarize.sh` submits, staples, and verifies, reading credentials from a
      `notarytool` keychain profile so no secret enters the repo or the environment
- [ ] PRD-015 gains the requirements; PRD-016's decision log records what the receipt proved

## Blocked on T-113 — deliberately out of scope here

Signing `install.sh` with a real identity is **not** in this task. T-113 (`e3b7fcdc`) owns
`install.sh` and is moving the replace/sign/verify block into `scripts/install-replace.sh`.
Editing that block now would destroy one of the two changes.

One thing must land there once T-113 is done:

- `--deep --sign` is not accepted for distribution. Signing must run inside-out: embedded
  frameworks → `tenon-cli` → app. `--deep` stays valid for `--verify`, where it means the
  opposite — "check nested code too".

**Do NOT add `--options runtime` to the ad-hoc re-sign.** Measured, not assumed: an ad-hoc
signature plus Hardened Runtime cannot load this app's own embedded frameworks.

```
dyld[39929]: Library not loaded: @rpath/OrderedCollections_….framework/…
  Reason: … code signature … not valid for use in process:
          mapping process and mapped file (non-platform) have different Team IDs
```

Hardened Runtime turns on Library Validation, which requires every loaded dylib to share the
process's Team ID. Ad-hoc has no Team ID to share, so the app dies at launch before `main`.
The app carries three embedded frameworks (`TenonCore`, `JSONSchema…`, `OrderedCollections…`),
so this is not avoidable by rearranging anything.

The consequence is the point of this task: **Hardened Runtime and ad-hoc are mutually
exclusive here.** `install.sh` stays ad-hoc and unhardened; hardening belongs only to the
Release/distribution path, where one identity signs the app and all three frameworks. It also
means `disable-library-validation` is NOT needed — signing them together satisfies the rule
that entitlement would waive.

## Owner / files (agent lock)

Session `407fc72f` — claimed 2026-08-10 21:3x. **`install.sh` deliberately NOT claimed.**

- `Tenon.entitlements` (new)
- `project.yml`
- `Tenon.xcodeproj/project.pbxproj` (regenerated by xcodegen)
- `scripts/notarize.sh` (new)
- `Tests/TenonCoreTests/AppSigningFitnessTests.swift` (new)
- `docs/operations.md`
- `docs/prds/engineering-quality.prd.md`
- `docs/prds/engineering-quality.feature`
- `docs/prds/diagnostics-and-resource-monitor.prd.md`
- `.kanban/board.md`, `.kanban/tasks/T-114-a-signature-the-system-remembers.md`
