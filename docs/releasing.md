# Releasing Tenon

How a build on this machine becomes something a stranger's Mac will run.

`./tenon install` and this document solve different problems, and the difference is the whole
subject. `./tenon install` puts a build on the machine that produced it: that machine already
trusts the bytes it just compiled, so an ad-hoc signature is enough and no certificate is
involved — which matters, because several agents build in this tree concurrently and none
of them should need one. A release goes to a machine that has never seen Tenon, where
Gatekeeper starts from the opposite assumption.

## What a signature buys, beyond Gatekeeper

An ad-hoc signature is a hash of the contents, so it changes with every build. macOS keys
two things to the code identity rather than to the path:

- **TCC consent.** Tenon runs agents in real PTYs, so a shell child reaching
  `~/Documents` prompts on Tenon's behalf. Under ad-hoc, the grant belongs to a signature
  that the next `./tenon install` replaces, and the prompt returns.
- **Keychain ACLs.** `SecretStore` writes `kSecClassGenericPassword` items
  (`Sources/TenonCore/SecretStore.swift:111`) whose access control names the app that
  created them.

A Developer ID signature is stable across builds, so both survive. This is the practical
reason to sign a build nobody is distributing.

## One-time setup

### 1. A Developer ID Application certificate

Distribution needs `Developer ID Application`. An `Apple Development` certificate cannot
sign for it — it only authorises running on registered machines.

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

Nothing listed means the certificate is not in this keychain. It is created from the
Apple Developer account that will own the release, by an Account Holder or Admin. The
Team ID in parentheses is what ends up embedded in every build, and it is what Gatekeeper
shows the user — under an Organization account that is the organization's legal name, not
the product's.

### 2. Notarization credentials

Stored once in the keychain, never in the repository or the environment:

```sh
xcrun notarytool store-credentials tenon-notary \
  --apple-id <you@example.com> \
  --team-id <TEAMID> \
  --password <app-specific-password>
```

The password is an **app-specific password** from <https://appleid.apple.com>, not the
Apple ID password. `tenon-notary` is the profile name the scripts default to; override
with `NOTARY_PROFILE`.

### 3. `.env`, so the configuration is in one readable place

```sh
cp .env.example .env      # then fill in the identity, team, and profile name
```

`scripts/internal/release-sign.sh` reads it, and `scripts/release.sh` reaches it through
that. It is gitignored, and an explicit value in the environment still beats the file, so a
one-off `SIGN_IDENTITY=… ./tenon release` continues to work.

What `.env` deliberately does not hold is the notarization password. It names
`NOTARY_PROFILE`, and the profile created in step 2 holds the Apple ID and app-specific
password inside the keychain, where macOS encrypts them. Moving that password into a
dotfile would take a real secret out of the keychain and put it somewhere backups, editors
and greps can reach — the file exists to collect configuration, not to become the place
secrets live.

## Cutting a release

```sh
./tenon publish               # everything below, then verify a stranger can install it
DRY_RUN=1 ./tenon publish     # everything except pushing a tag, release or cask
```

`publish` runs `./tenon release` for the artifact, so the artifact step is also available
on its own while iterating on signing:

```sh
./tenon release               # verify, build universal, sign, notarize, staple, package
```

`release.sh` refuses to continue when the generated Xcode project differs from the
committed one, and warns — without stopping — when the worktree is dirty, because a
release built from uncommitted work cannot be reproduced from its own commit.

It produces:

```
dist/Tenon-<version>-macos.zip          universal, signed, notarized, stapled
dist/Tenon-<version>-macos.zip.sha256
dist/SHA256SUMS
dist/tenon.rb                           the Homebrew cask (from make-cask.sh)
```

The final check extracts the zip and verifies *that* copy. A bundle verified in place
proves nothing about the file people receive — the stapled ticket has to survive the
round trip.

### Version

`MARKETING_VERSION` in `project.yml` is the source. Bump it, run `.build/tools/xcodegen/bin/xcodegen generate`, and
commit the regenerated project before cutting.

### Publishing

```sh
./tenon publish
```

It reads the version out of the built app, tags, uploads the archive and its checksums,
writes the cask, and checks that a stranger can install the result. See **One road out**
below for what it refuses to do halfway.

Release notes distinguish implemented capability from roadmap. Tenon is pre-alpha and its
README says so; a release that reads as finished product is the one mistake this step can
make on its own.

## Homebrew

Tenon installs as a **cask** (a GUI application), from a **tap of our own** rather than
`homebrew/cask`. The central repository requires a project to be notable and stable, which
this is not yet, and a tap costs nothing to run:

```sh
gh repo create <owner>/homebrew-tap --public
TAP_REPO=~/projects/homebrew-tap ./tenon publish
cd ~/projects/homebrew-tap && git add Casks/tenon.rb && git commit -m "tenon <version>" && git push
```

Users then:

```sh
brew tap <owner>/tap
brew install --cask tenon
```

`make-cask.sh` reads version, checksum, bundle identifier and minimum macOS out of the
built artifact, so none of them can be copied wrong.

**The repository must be public first.** Homebrew fetches the release asset with no
credentials; a cask pointing into a private repository installs for nobody.
`make-cask.sh` checks this and says so rather than letting the first `brew install`
discover it.

The cask deliberately does not symlink `tenon-cli` into Homebrew's bin. Tenon installs the
CLI itself from **Settings ▸ CLI ▸ Install**, which owns its location and keeps it matched
to the running app; a second path to the same file lets a stale symlink outlive the bundle
it points into.

## One road out

`./tenon publish` is the only thing in this repository that creates a GitHub release. It
runs `./tenon release` for the artifact, tags, uploads, writes the cask, and then
downloads the published archive anonymously and installs it, so the last thing the
procedure proves is the thing a stranger actually gets.

The Developer ID certificate and its private key stay on the machine that holds them.
Signing on a shared runner would mean exporting that key as a `.p12` into a repository
secret — the one credential here that cannot be re-issued silently, since revoking it
invalidates signatures on builds already distributed unless they were notarized and
timestamped. `release-sign.sh` passes `--timestamp` for exactly that reason, and the key
staying local is the cheaper half of the same protection.

CI's job is therefore the build and the test suite (`.github/workflows/macos-ci.yml`), and
the release is cut by a person who can see Apple's verdict as it arrives.

## What was measured, so it is not re-derived

Recorded 2026-08-10 against `Tenon.app` built from this tree. These are receipts, not
reasoning — each was contradicted or confirmed by running it.

### Hardened Runtime and ad-hoc signatures are mutually exclusive here

`--options runtime` turns on **Library Validation**, which requires every loaded dylib to
share the process's Team ID. Tenon embeds three frameworks (`TenonCore`, `JSONSchema…`,
`OrderedCollections…`). An ad-hoc signature has no Team ID to share, so the app dies in
dyld before `main`:

```
Library not loaded: @rpath/OrderedCollections_….framework/…
  Reason: … not valid for use in process:
          mapping process and mapped file (non-platform) have different Team IDs
```

Signed with one Developer ID identity — app and all three frameworks — the same build
launches. **Consequence:** `./tenon install` stays ad-hoc and unhardened; adding `--options
runtime` to its re-sign would break every local install. And `disable-library-validation`
is *not* needed: signing everything together satisfies the rule that entitlement waives.

### JavaScriptCore keeps its JIT, with one entitlement

`Tenon.entitlements` grants `com.apple.security.cs.allow-jit` and nothing else. Under
Developer ID + Hardened Runtime, the bundled Kanban plugin's JavaScript rendered a view
**byte-identical** to the unhardened control (`TENON_VIEW_SNAPSHOT`).

The escape entitlements form a widening cascade — `allow-jit` →
`allow-unsigned-executable-memory` → `disable-executable-page-protection` — and exactly
one may be set (`research-plugin-runtimes.md:994`). JavaScriptCore needs the narrowest.
`AppSigningFitnessTests` asserts the wider ones stay absent, so adding one turns the suite
red rather than passing review unnoticed.

### Hardened Runtime does not restrict `libproc`

This was PRD-016's open *signed-app feasibility* question: the Resource Monitor had only
ever run unhardened. The same probe binary, signed twice, differing only in the runtime
flag:

| | `listpids` | `PROC_PIDTBSDINFO` | `EPERM` | `PROC_PIDTASKINFO` | `proc_pidpath` |
|---|---|---|---|---|---|
| unhardened | 638 | 419 | 219 | 419 | 635 |
| hardened | 638 | 419 | 219 | 419 | 635 |

Identical. The 219 refusals are processes owned by root or other users, present in both.
Process telemetry survives distribution unchanged.

### Notarization, first real submission

Submission `9599ec16-d60a-4e7a-b6ad-d43bbfe981ef` on 2026-08-10 returned `status: Accepted`
for the universal 0.1.0 archive. The ticket stapled, and a copy extracted back out of the
published zip assessed as:

```
accepted
source=Notarized Developer ID
```

Nothing in the entitlements or the signing shape needed changing to get there — the
`allow-jit`-only entitlement set and the inside-out signature passed Apple's checks on the
first attempt.

### Build settings are not the artifact

`ENABLE_HARDENED_RUNTIME` in `project.yml` applies only when the build actually signs.
`./tenon install` passes `CODE_SIGNING_REQUIRED=NO`, under which `xcodebuild` runs no
`codesign` step at all — the `flags=0x2(adhoc)` such a build carries comes from the
linker. `scripts/internal/release-sign.sh` is therefore the authority for what a distributed
artifact is signed with, and it verifies the flag word on the bundle rather than trusting
the setting that asked for it.

## Troubleshooting

**`different Team IDs` at launch** — the app and its embedded frameworks were signed by
different identities, or one is still ad-hoc. Re-run `release-sign.sh`, which signs all of
them inside-out.

**Notarization rejected** — `xcrun notarytool log <submission-id> --keychain-profile
tenon-notary` gives the per-file reason. The usual causes are a nested binary that was
never signed, a missing `--options runtime`, or `com.apple.security.get-task-allow` left
in the entitlements.

**`brew install` 404s** — the repository or the release asset is not public.

**`--deep` while signing** — not accepted for distribution: it re-signs nested code with
the outer entitlements and skips anything it does not recognise as code. `--deep` on
`codesign --verify` is a different flag with the opposite meaning ("check nested code
too") and is correct there.

## Related

- [`operations.md`](operations.md) — the release checklist this implements, plus runtime
  troubleshooting
- [`development.md`](development.md) — local build and layout
- PRD [`engineering-quality`](prds/engineering-quality.prd.md) — the owning requirements
- PRD [`diagnostics-and-resource-monitor`](prds/diagnostics-and-resource-monitor.prd.md) —
  the signed-app telemetry question closed above
