# Development, troubleshooting, and release operations

**Status:** current runbook · **Reviewed:** 2026-08-06

This is the operational entry point for the native app. Product architecture and plugin
contracts are indexed in [`README.md`](README.md).

## Build and test

Prerequisites are macOS 14+, Xcode, and XcodeGen 2.45.4 or newer.

```sh
./scripts/setup-ghosttykit.sh
xcodegen generate
xcodebuild \
  -project Tenon.xcodeproj \
  -scheme Tenon \
  -configuration Debug \
  -derivedDataPath .build/xcode \
  -clonedSourcePackagesDirPath .build \
  build
```

Fast headless verification:

```sh
swift build
swift test
```

Complete hosted verification:

```sh
xcodegen generate
xcodebuild test \
  -project Tenon.xcodeproj \
  -scheme Tenon \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode \
  -clonedSourcePackagesDirPath .build
```

XCUITest requires a logged-in GUI session. Test counts are deliberately not recorded in
documentation because they drift; the command output is the verification receipt. A valid
receipt records the commit/worktree, command, destination, exit code, and failing test names
if any.

## Runtime locations and overrides

Tenon keeps durable application state under the user's Application Support directory. The
state includes the workspace catalog, plugin installation identities and enablement,
plugin-private storage, intent idempotency/consent data, and authored plugins. Do not edit
these files while Tenon is running.

Useful development overrides:

- `TENON_WORKSPACE_PATH` selects the initial workspace/terminal directory.
- `TENON_PLUGINS_DIR` selects a writable primary development inventory.
- `TENON_STUB_TERMINAL=1` replaces PTYs with deterministic content for UI smoke runs.
- `TENON_TRUST_PLUGIN_INVENTORY=1` trusts only the primary override as a bundled-equivalent
  development fixture. It auto-enables newly discovered plugins there and seeds standing
  consent. Any other value, including `true`, leaves it untrusted. The separate user plugin
  inventory is always untrusted.

An untrusted plugin is disabled before first execution. Enabling it grants in-process code
execution trust, not just a list of capabilities: JavaScriptCore isolation is not a hard
process sandbox. Intent declarations, permission checks, scopes, and consent still limit
the host APIs the plugin can invoke. Disable or remove a plugin to revoke its runtime and
cancel its resources; uninstall/reinstall receives a fresh installation identity.
Changing an existing plugin ID between bundled-equivalent and untrusted inventory classes
also rotates that identity. A downgrade starts disabled and cannot inherit the former
principal's settings, storage, secrets, or standing consent.

## Troubleshooting

### App does not build

1. Re-run `./scripts/setup-ghosttykit.sh` and confirm the pinned artifact completed its
   integrity check before extraction.
2. Run `xcodegen generate`; `project.yml` is authoritative and the checked-in project must
   not drift from it.
3. Use the same `.build` paths as the commands above so SwiftPM and Xcode do not resolve
   different package trees.
4. Run `swift build` first to isolate Swift compilation from signing, UI hosting, and PTY
   failures.

### A plugin is discovered but does not run

- Check Settings for a disabled newly discovered plugin and enable it only after reviewing
  its manifest and source.
- Confirm the directory contains readable `manifest.json` and `main.js` files and that the
  manifest ID is unique.
- Every sent intent must be in `intents.uses`; every handler must be in
  `intents.provides` and bound exactly once during staging.
- A syntax, manifest, schema, or binding error leaves the last good generation running;
  inspect the plugin error and attributed logs instead of assuming the edit loaded.
- For plugin-published events, declare the local channel in `events.publishes`; observers
  declare the fully qualified channel in `events.observes`.

### An intent is denied or times out

- Use discovery (`tenon-cli intent list` and `intent describe`) to confirm the caller's
  audience can see the contract.
- Verify the plugin manifest capability, network host allowlist, and workspace/pane scope.
- Policy-confirmed operations require a live interactive confirmation. CLI and agent
  callers do not receive standing consent; unattended policy operations expire rather than
  silently escalating.
- A deadline covers admission, confirmation, provider execution, and settlement. Increasing
  it can diagnose slow work but must not be used to turn a stream into a held intent.

### Restored workspace looks incomplete

Restore is fail-soft. Missing workspace directories are dropped; invalid tabs are dropped;
unknown or unavailable pane content becomes an empty pane. Terminal panes restore identity,
layout, title, and working-directory placeholders, but launch a fresh shell only when
materialized. A terminal process is never serialized and resurrected.

If the catalog is corrupt, preserve a copy for diagnosis before moving it aside. Do not
delete the whole Application Support tree: plugin installation IDs, enablement, private
storage, and consent records are independent state.

### Agent Lens is degraded

Agent Lens needs an authoritative provider session binding. For Codex, verify the additive
hook was installed in the active `CODEX_HOME`, the provider approved it, and the transcript
is a current-user regular JSONL file under `CODEX_HOME/sessions`. A stale process, child
agent fact, mismatched process group, or rotated terminal-surface token is rejected. When
binding is unavailable, use Terminal mode as the exact evidence path; Tenon does not guess
the newest transcript by directory and modification time.

## Release checklist

1. Start from a clean, reviewed worktree and record the intended version and commit.
2. Fetch the pinned Ghostty artifact through `setup-ghosttykit.sh`; require the expected
   digest/signature check to pass before extraction. Record the artifact tag and digest.
3. Run `xcodegen generate` and assert the generated project has no unexplained diff.
4. Run `swift build`, `swift test`, the complete macOS scheme, architecture fitness tests,
   and XCUITest in a logged-in GUI session. Keep command receipts rather than copying a test
   count into docs.
5. Run the internal-link and removed-surface sweeps below.
6. Run `./scripts/release.sh`. It builds Release universal, signs the app, its three
   embedded frameworks and the bundled CLI inside-out, notarizes, staples, packages, and
   then verifies a copy extracted back out of the archive. [`releasing.md`](releasing.md)
   is the full procedure, including the one-time certificate and notarization setup and
   the measured reasons the signing shape is what it is.
7. Install the produced artifact on a clean user account. Verify first launch, single
   instance focus, workspace restore, plugin enable/disable, consent, hot reload, terminal
   creation, and Agent Lens degradation behavior.
8. Publish checksums and release notes that distinguish implemented capability from roadmap.
9. Update the Homebrew cask with `./scripts/make-cask.sh`, which derives every value from
   the artifact rather than repeating it by hand.

Do not describe the app as sandboxing untrusted plugins until JavaScript runs behind a hard
isolation boundary with termination and memory limits.

## Verification receipt

Check internal Markdown links:

```sh
ruby -e 'fs=["README.md","VISION.md","Tests/TenonUITests/README.md"]+Dir["docs/**/*.md"]; fs.each { |f| File.read(f).scan(/\[[^\]]*\]\((?!https?:|mailto:|#)([^)#]+)(?:#[^)]+)?\)/).flatten.each { |p| q=File.expand_path(p,File.dirname(f)); abort "#{f}: #{p}" unless File.exist?(q) } }'
```

Check that deleted v0.2 runtime names did not return:

```sh
rg -n 'tenon\.(commands|sidebar|workspace|terminal|fs\.(readDir|readFile|exists|writeFile)|process\.exec)' \
  Sources/TenonCore plugins examples docs README.md VISION.md \
  --glob '*.swift' --glob '*.js' --glob '*.md'
```

The expected result is empty. Architecture fitness tests separately retain the deleted
strings as negative fixtures; app accessibility IDs and provider IDs are not JavaScript
runtime paths, so this author-facing sweep deliberately targets the runtime, shipped plugin,
example, and documentation surfaces.
